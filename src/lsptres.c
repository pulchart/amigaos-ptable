/*
 * lsptres - list partition.resource
 *
 * Dumps the partitions published by ptable.library scanner
 * (RDB, MBR, GPT and superfloppy "flat" layouts), whether
 * cold-registered at boot or hot-mounted at runtime.
 *
 */

/* Version string macros (VERSION/DATE injected by the Makefile via -D) */
#define STR_HELPER(x) #x
#define STR(x) STR_HELPER(x)
#define MAKE_VERSION_STRING(toolname) \
    "$VER: " toolname " " STR(VERSION) " (" STR(DATE) ")"

const char version[] = MAKE_VERSION_STRING("lsptres");

#include <exec/types.h>
#include <exec/nodes.h>
#include <exec/lists.h>
#include <exec/semaphores.h>

#include <dos/rdargs.h>
#include <proto/exec.h>
#include <proto/dos.h>

#include <stdio.h>

#define PART_RESOURCE_NAME "partition.resource"

/* pe_Source values (ptable_pub.i) */
#define PES_MBR  0
#define PES_GPT  1
#define PES_RDB  2
#define PES_FLAT 3

/* pe_ReadMode values (ptable_pub.i PERM_*) */
#define PERM_NSCMD 1
#define PERM_TD64  2
#define PERM_SCSI  3
#define PERM_CMD   4

/* pe_Flags masks (ptable_pub.i defines bit NUMBERS; these are masks) */
#define PEF_PRESENT  (1<<0)
#define PEF_BOOTABLE (1<<1)
#define PEF_NOMOUNT  (1<<2)
#define PEF_MOUNTED  (1<<3)
#define PEF_INVALID  (1<<4)

/* partition.resource layout: MUST mirror ptable_pub.i, append-only,
 * new fields are only ever added at the end (never inserted), guarded by
 * pr_Layout / pe_Length. Keep this block in lockstep with ptable_pub.i. */
struct PartResource {
    struct Node            pr_Node;       /*  0..13 */
    UBYTE                  pr_libpad[20]; /* 14..33  LIB_Flags..LIB_OpenCnt */
    struct List            pr_PartList;   /* 34 */
    struct SignalSemaphore pr_Lock;       /* 48 (46 bytes) */
    UWORD                  pr_Layout;     /* 94  layout version (PTR_LAYOUT_V) */
    UWORD                  pr_EntrySize;  /* 96  publisher's pe_Sizeof */
};                                        /* 98 */

#define PTR_LAYOUT_KNOWN 2  /* highest layout this tool understands */

/* PartEntry (ptable_pub.i; layout = PTR_LAYOUT_KNOWN) */
struct PartEntry {
    struct Node  pe_Node;        /*  0  (ln_Name -> pe_NameB) */
    char        *pe_Device;      /* 14 */
    ULONG        pe_Unit;        /* 18 */
    ULONG        pe_PartIndex;   /* 22 */
    UBYTE        pe_Source;      /* 26 */
    UBYTE        pe_Flags;       /* 27 */
    LONG         pe_BootPri;     /* 28 */
    ULONG        pe_StartLBA;    /* 32 */
    ULONG        pe_BlockCount;  /* 36 */
    ULONG        pe_DosType;     /* 40 */
    APTR         pe_DevNode;     /* 44 */
    APTR         pe_BlobPtr;     /* 48 */
    ULONG        pe_BlobSize;    /* 52 */
    UBYTE        pe_NameB[32];   /* 56  (BSTR) */
    ULONG        pe_Envec[21];   /* 88 */
    UBYTE        pe_ReadMode;    /* 172 */
    UBYTE        pe_pad;         /* 173 */
    UBYTE        pe_MountName[32];/* 174 (BSTR) */
    UBYTE        pe_pad2[2];     /* 206 (pad to pe_MountFlags) */
    ULONG        pe_MountFlags;  /* 208 */
    UBYTE        pe_Control[32]; /* 212 (BSTR) */
    UWORD        pe_Length;      /* 244 allocated entry size (bounds-check
                                  *     appended fields against this) */
    UBYTE        pe_Reserved[14];/* 246..259 */
};                               /* 260 */

static const char *src_name(UBYTE s)
{
    switch (s) {
    case PES_MBR:  return "MBR";
    case PES_GPT:  return "GPT";
    case PES_RDB:  return "RDB";
    case PES_FLAT: return "FLT";
    }
    return "?? ";
}

static void print_dostype(ULONG dt)
{
    int i;
    for (i = 24; i >= 0; i -= 8) {
        UBYTE c = (UBYTE)(dt >> i);
        putchar((c >= 0x20 && c < 0x7f) ? c : '.');
    }
}

static const char *cmd_name(UBYTE m)
{
    switch (m) {
    case PERM_NSCMD: return "NSCMD";
    case PERM_TD64:  return "TD64";
    case PERM_SCSI:  return "SCSI";
    case PERM_CMD:   return "CMD";
    }
    return "?";
}

/* pe_Control BSTR -> C string (empty when no CONTROL resolved); a statically
   mounted node may carry its mountlist CONTROL with surrounding quotes, so
   strip one matched leading+trailing pair for display. */
static const char *ctrl_str(const struct PartEntry *pe)
{
    static char s[33];
    int len = pe->pe_Control[0], i, off = 0;
    if (len > 31)
        len = 31;
    if (len >= 2 && pe->pe_Control[1] == '"' && pe->pe_Control[len] == '"') {
        off = 1;
        len -= 2;
    }
    for (i = 0; i < len; i++)
        s[i] = pe->pe_Control[1 + off + i];
    s[i] = '\0';
    return s;
}

/* 4-char flag picture. First char is three-valued: P present, I invalid
   (a card is in but it has no partition for this mounted slot), - absent. */
static const char *flags_str(UBYTE f)
{
    static char s[5];
    s[0] = (f & PEF_PRESENT) ? 'P' : (f & PEF_INVALID) ? 'I' : '-';
    s[1] = (f & PEF_BOOTABLE) ? 'B' : '-';
    s[2] = (f & PEF_NOMOUNT)  ? 'N' : '-';
    s[3] = (f & PEF_MOUNTED)  ? 'M' : '-';
    s[4] = '\0';
    return s;
}

/* merged Name column: the partition name, plus ">dosname" when the partition
   is mounted under a different DOS name (e.g. "MFMb0>MS"). Mount state itself
   is read from the M flag, shown on every row. */
static const char *merged_name(const struct PartEntry *pe)
{
    static char s[40];
    const UBYTE *b = pe->pe_NameB;
    const UBYTE *m = NULL;
    int n = 0, i, len, ml, same;

    len = b[0];
    if (len > 31)
        len = 31;
    for (i = 0; i < len; i++)
        s[n++] = b[1 + i];

    if (pe->pe_MountName[0])
        m = pe->pe_MountName;
    else if (pe->pe_Flags & PEF_MOUNTED)
        m = pe->pe_NameB;

    if (m) {
        ml = m[0];
        if (ml > 31)
            ml = 31;
        same = (ml == len);
        for (i = 0; same && i < len; i++)
            if (m[1 + i] != b[1 + i])
                same = 0;
        if (!same) {
            s[n++] = '>';
            for (i = 0; i < ml; i++)
                s[n++] = m[1 + i];
        }
    }
    s[n] = '\0';
    return s;
}

/* Default columns plus, when verbose, Start/Blocks/Size */
static void view_all(struct List *list, int verbose)
{
    struct Node *n;
    struct PartEntry *pe;

    printf("%-12s %-13s %4s %4s %-3s %3s %-10s %-4s %-5s %5s %-10s",
           "Name", "Device", "Unit", "Part", "Src", "Pri",
           "DosType", "Text", "Flags", "MFlg", "Ctrl");
    if (verbose)
        printf(" %-5s %10s %11s %6s", "CMD", "Start", "Blocks", "Size");
    printf("\r\n");

    printf("%-12s %-13s %4s %4s %-3s %3s %-10s %-4s %-5s %5s %-10s",
           "------------", "-------------", "----", "----", "---", "---",
           "----------", "----", "-----", "-----", "----------");
    if (verbose)
        printf(" %-5s %10s %11s %6s", "-----", "----------", "-----------", "------");
    printf("\r\n");

    for (n = list->lh_Head; n->ln_Succ; n = n->ln_Succ) {
        pe = (struct PartEntry *)n;
        printf("%-12s %-13.13s %4lu %4lu %-3s %3ld 0x%08lX ",
               merged_name(pe),
               pe->pe_Device ? pe->pe_Device : (char *)"?",
               (unsigned long)pe->pe_Unit,
               (unsigned long)pe->pe_PartIndex,
               src_name(pe->pe_Source),
               (long)pe->pe_BootPri,
               (unsigned long)pe->pe_DosType);
        print_dostype(pe->pe_DosType);
        printf(" %-5s %5lu %-10s",
               flags_str(pe->pe_Flags),
               (unsigned long)pe->pe_MountFlags,
               ctrl_str(pe));
        if (verbose)
            printf(" %-5s %10lu %11lu %5luM",
                   cmd_name(pe->pe_ReadMode),
                   (unsigned long)pe->pe_StartLBA,
                   (unsigned long)pe->pe_BlockCount,
                   (unsigned long)(pe->pe_BlockCount / 2048));
        printf("\r\n");
    }
}

static void usage(void)
{
    printf("lsptres " STR(VERSION) " - list partition.resource\r\n"
           "Usage: lsptres [VERBOSE|V]\r\n"
           "  VERBOSE (V)  also show CMD / Start / Blocks / Size (lines may wrap)\r\n"
           "\r\n"
           "Name:  partition name, plus \">dosname\" when mounted under another name\r\n"
           "Src:   MBR GPT RDB FLT   (partition scheme)\r\n"
           "Flags: P present  I invalid (card in, slot not on it)  B bootable  N nomount  M mounted\r\n"
           "MFlg:  mount Flags (node fssm_Flags from cfd.prefs)\r\n"
           "Ctrl:  CONTROL string resolved for this mount\r\n"
           "CMD:   (verbose) read command: NSCMD / TD64 / SCSI / CMD\r\n");
}

int main(void)
{
    struct PartResource *res;
    struct RDArgs *rda;
    LONG opt[1] = { 0 };   /* VERBOSE */

    rda = ReadArgs("VERBOSE=V/S", opt, NULL);
    if (!rda) {
        usage();
        return 0;
    }

    res = (struct PartResource *)OpenResource(PART_RESOURCE_NAME);
    if (!res) {
        printf("%s not present (nothing scanned yet)\r\n",
               PART_RESOURCE_NAME);
        FreeArgs(rda);
        return 0;
    }

    /* layout stamps exist only when the publisher's header is big enough
     * (struct Library lib_PosSize at offset 18; header grew 94 -> 98) */
    {
        UWORD possize = *(UWORD *)((UBYTE *)res + 18);
        if (possize >= 98 && res->pr_Layout > PTR_LAYOUT_KNOWN)
            printf("note: resource layout v%u is newer than this tool (v%u); "
                   "appended fields are not shown\r\n",
                   res->pr_Layout, PTR_LAYOUT_KNOWN);
        if (opt[0] && possize >= 98)
            printf("layout v%u, entry size %u\r\n",
                   res->pr_Layout, res->pr_EntrySize);
    }

    Forbid();
    view_all(&res->pr_PartList, opt[0] ? 1 : 0);
    Permit();

    FreeArgs(rda);
    return 0;
}
