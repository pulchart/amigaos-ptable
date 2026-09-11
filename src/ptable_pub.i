; ptable.library v2 - public interface
;
; Scans RDB, MBR, GPT and whole-disk FAT into partition.resource. Cold
; registration and runtime mount/unmount consume these published entries.
; Shared by library and consumers; fat95/lsptres maintain offset mirrors.
;
; Calls: a6 = library base; deviceName = NUL-terminated C string.
; Preserve d2-d7/a2-a6; d0 is the result, d1/a0-a1 are scratch.
; Call from task context, never an interrupt; Mount/Unmount require a Process.
; Count results may be partial; zero also covers failure, with no error code.

;--- LVOs (Open/Close/Expunge/Reserved = -6..-24) --------------------------
;
; BootScanPartitions(deviceName:a1, unit:d0) -> d0 = registered count
;   RTF_COLDSTART, pre-DOS only. Publish all schemes, load RDB filesystems into
;   FileSystem.resource, register mountable RDB entries via AddBootNode
;   (bootable) or AddDosNode(flags=0). MBR/GPT/flat await runtime mounting.
;   Add a synthetic ConfigDev when nodes exist; System-Startup starts handlers.
;
; ScanPartitions(deviceName:a1, unit:d0) -> d0 = newly published count
;   Exec-only. Scan and publish; never mount. May wait for PTR_Lock/device I/O.
;
; MountPartitions(deviceName:a1, unit:d0, cfg:a0) -> d0 = mounted count
;   Process only. Start eligible unmounted entries via AddDosNode(ADNF_STARTPROC).
;   cfg = MountCfg or 0 for defaults. Resolve Flags/CONTROL by pe_DosType;
;   record results in pe_MountFlags/pe_Control and the node's fssm_Flags/de_Control.
;   mc_NodeDosType/mc_NodeHandler select the handler for synthesized FAT entries;
;   pe_NodeDosType records the node's resolved DosType. RDB geometry is retained.
;
; UnmountPartitions(deviceName:a1, unit:d0, prefixList:a0) -> d0 = teardown count
;   Process only. Drop unmounted records for this device/unit. For mounted
;   entries, request ACTION_DIE, then remove/free only after confirmed teardown.
;   prefixList = 0 selects all; otherwise a zero-terminated ULONG array selects
;   pe_DosType high-three-byte prefixes (e.g. $50465300 for PFS).
;   Unselected or retained handlers stay mounted and are marked absent.
;   Static nodes (pe_BlobPtr=0: hand-mounted or adopted) with PEB_KEEPSTATIC
;   are only marked absent in either mode; the caller owns their removal.
;   MountPartitions stamps this policy from mc_UnmFlags on each mount pass;
;   lsptres displays it as S/s.

;--- MountCfg (-> MountPartitions in a0; 0 = cold-boot defaults) -----------
;
; Resolve overrides by pe_DosType & $FFFFFF00, falling back to global values.
; Caller owns the structure, table and C strings through the call; retained
; strings are copied. mc_NodeDosType/mc_NodeHandler apply only to synthesized
; MBR/GPT/flat FAT entries; RDB retains its on-disk DosType and geometry.
;
mc_Flags	= 0			;ULONG global fssm_Flags
mc_Control	= 4			;APTR  global CONTROL C-string (0 = none)
mc_Overrides	= 8			;APTR  override table (0 = none)
mc_NodeDosType	= 12			;ULONG override node DosType; 0 = scanned envec
					;nonzero also restricts its window to this
					;partition's blocks (no handler auto-detection)
mc_NodeHandler	= 16			;APTR handler C-string, e.g. "L:Something"
					;fallback only if no FileSysEntry matches;
					;0 = FileSystem.resource only
mc_Size		= 20			;ULONG caller's structure size in bytes
					;baseline fields above are always read;
					;appended fields require sufficient size
mc_UnmFlags	= 24			;ULONG MCUF_* bits; read only if mc_Size >= 28
					;mount pass stamps entry policy, including
					;already-mounted entries; older cfg leaves it
					;unchanged
mc_Sizeof	= 28

MCUF_KEEPSTATIC	= 0			;keep static mounts on card removal
					;(-> PEB_KEEPSTATIC)
MCUF_STAMPONLY	= 1			;walk + stamp the policy, mount nothing
					;(caller has its own mounting disabled)
MCUF_MOUNTUSED	= 2			;a hand mountlist may claim an entry another
					;handler already serves (-> PEB_MOUNTUSED)
;
; Override row (array terminated by ovr_Prefix = 0):
ovr_Prefix	= 0			;ULONG dostype high 3 bytes ('DOS\0' etc); 0 = end
ovr_Flags	= 4			;ULONG override fssm_Flags
ovr_HasFlags	= 8			;UBYTE 1 = FLAGS_<fs> present (else use global)
;		  9..11			;(pad)
ovr_Control	= 12			;APTR  override CONTROL C-string (0 = use global)
ovr_Sizeof	= 16
;
; ovr_Sizeof is fixed across versions: changing it breaks table traversal.
; Append new settings to MountCfg, gated by mc_Size.

_LVOBootScanPartitions	= -30
_LVOScanPartitions	= -36
_LVOMountPartitions	= -42
_LVOUnmountPartitions	= -48
_LVORegisterPartition	= -54
_LVOMarkAbsent		= -60
_LVOUnregisterPartition	= -66
;
; RegisterPartition(deviceName:a1, unit:d0, startLBA:d1, blockCount:d2,
;   nameBSTR:a0, devNode:a2, flags:d3, control:d4, nodeDosType:d5) -> d0 = 1/0
;   Exec-only; may wait for PTR_Lock. Match a published device/unit/startLBA;
;   blockCount is currently unused (filesystem and partition sizes may differ).
;   Record MOUNTED, devNode, flags and nodeDosType (0 = unknown), and copy name
;   and CONTROL into pe_MountName/pe_Control, truncated to 31 characters.
;   nameBSTR/control are byte pointers to BSTRs, not BPTRs; control may be 0.
;   Strings need only survive the call; devNode must remain valid while mounted.
;   Return 1 for registration/rebind; 0 for no match or allocation failure.
;   Rebind the caller's existing row, including a shadow. If another node owns
;   the primary row, clone a PEB_SHADOW row instead of replacing its owner.
;   New register inputs require a new LVO; this call has no size negotiation.
;
; UnregisterPartition(deviceName:a1, unit:d0, startLBA:d1, devNode:a2)
;   -> d0 = 1 cleared, 0 no match/null node/busy lock/allocation failure
;   Exec-only, best-effort PTR_Lock. Only the matching node can unregister.
;   Clear MOUNTED/INVALID, node/name and recorded mount values; retain scan data.
;   A shadow row is freed instead. Does not stop the handler or remove its DOS
;   node; use when the handler leaves voluntarily outside a ptable teardown.
;
; MarkAbsent(deviceName:a1, unit:d0) -> d0 = matching entries processed
;   Exec-only, best-effort PTR_Lock; return 0 if unavailable. Clear PRESENT and
;   INVALID, retaining mount/node/handler state. Count includes already-absent
;   entries. Device notification ejects the handler's volume; a later scan
;   restores PRESENT. Use UnmountPartitions for selective handler teardown.

;--- partition.resource ----------------------------------------------------
;
;   0..33  struct Library head (NT_RESOURCE, LN_Name = "partition.resource",
;          LIB_Version/Revision/IdString set) so resource viewers display it
;          cleanly; LIB_Sizeof = 34
;  34      ptr_PartList  embedded List of PartEntry (14 bytes)
;  48      ptr_Lock      embedded SignalSemaphore (46 bytes)
;  94      ptr_Layout    UWORD layout version (PTR_LAYOUT_V)
;  96      ptr_EntrySize UWORD pe_Sizeof the publisher was built with
;  98      ptr_Sizeof
;
; LVOs serialize resource access with PTR_Lock. MarkAbsent and
; UnregisterPartition only attempt the lock and skip when busy. Readers may
; protect a list walk with Forbid() or take PTR_Lock for a coherent snapshot.
; Do not retain entry/string pointers after releasing protection.
;
; ABI GROWTH CONTRACT (applies to this header AND PartEntry):
;   - new fields are APPENDED only; inserting mid-struct is forbidden
;     forever (lsptres and fat95 ship separately-built offset mirrors)
;   - every append bumps PTR_LAYOUT_V; a consumer that needs a newer
;     field checks ptr_Layout (or pe_Length) >= what it requires and
;     degrades gracefully otherwise
;   - OpenResource() cannot negotiate versions, so these stamps are the
;     ONLY runtime layout signal

PTR_PartList	= 34
PTR_Lock	= 48
PTR_Layout	= 94
PTR_EntrySize	= 96
PTR_Sizeof	= 98

PTR_LAYOUT_V	= 5			;bump on every appended field (or newly
					;defined pe_Flags bit); v4 = the policy
					;bits, v5 = PEB_SHADOW extra-mount rows

;--- PartEntry (one per discovered partition; layout = PTR_LAYOUT_V) -------
;
; Grouped by role: identity, classification, geometry summary (lister
; convenience; pe_Envec is the mount master), mount state, then the
; embedded name and DosEnvec materialised at publish time.

pe_Node		= 0			;LN_Name -> pe_NameB
pe_Device	= 14			;APTR device-name C-string copy
pe_Unit		= 18			;ULONG
pe_PartIndex	= 22			;ULONG table slot / GPT entry index
pe_Source	= 26			;UBYTE PES_* below
pe_Flags	= 27			;UBYTE PEB_* bit numbers below
pe_BootPri	= 28			;LONG  RDB DE_BOOTPRI, else 0
pe_StartLBA	= 32			;ULONG
pe_BlockCount	= 36			;ULONG
pe_DosType	= 40			;ULONG
pe_DevNode	= 44			;APTR  registered DeviceNode (0 = none)
pe_BlobPtr	= 48			;APTR  DN blob AllocMem ptr
pe_BlobSize	= 52			;ULONG
pe_NameB	= 56			;32 bytes embedded BSTR (see naming below)
pe_Envec	= 88			;84 bytes: TableSize+1 longs (max 21)
pe_ReadMode	= 172			;UBYTE read command used (PERM_* below)
;		  173			;(pad)
pe_MountName	= 174			;32 bytes embedded BSTR: real DOS device
					;name when actually mounted (else empty);
					;the generated pe_NameB is never overwritten
;		  206			;(2 pad: keep pe_MountFlags 4-aligned for C)
pe_MountFlags	= 208			;ULONG resolved mount Flags (node fssm_Flags)
pe_Control	= 212			;32 bytes embedded BSTR: resolved CONTROL string
pe_Length	= 244			;UWORD allocated entry size, stamped = pe_Sizeof
					;at publish; consumers bounds-check appended
					;fields against it (see growth contract above)
;		  246..247		;(2 pad: keep pe_NodeDosType 4-aligned)
pe_NodeDosType	= 248			;ULONG mounted node DosType (layout 3), else 0
					;resolved per mount or RegisterPartition;
					;pe_DosType remains detected type for
					;Flags/CONTROL/UNMOUNT prefix matching
;		  252..259		;reserved for appended fields (zeroed)
pe_Sizeof	= 260

;-- pe_ReadMode values (the device read command, see ptable_boot.s probe)
PERM_UNPROBED	= 0
PERM_NSCMD	= 1			;NSCMD_TD_READ64
PERM_TD64	= 2			;TD_READ64
PERM_SCSI	= 3			;HD_SCSICMD (READ(10))
PERM_CMD	= 4			;CMD_READ

; pe_NameB naming:
;   RDB    -> the on-disk pb_DriveName, verbatim.
;   MBR/GPT/FLAT (no on-disk name) -> synthesized as
;            <PREFIX>[<unit-letter>]<partition-number>
;            PREFIX device abbreviation (see below)
;            unit   'a'+unit  (a = unit 0, b = unit 1, ... p = unit 15);
;                   omitted for unit 0 of a table entry flagged
;                   DABF_NOUNIT (single-unit device)
;            part   decimal partition number, 0-based
;            e.g. compactflash.device unit 0 -> CF0 CF1 CF2 (DABF_NOUNIT)
;                 scsi.device         unit 0 -> SCSIa0 SCSIa1 ...
;   The prefix comes from a known-device abbreviation table
;   (compactflash.device -> CF; extend s_devAbbrevTable in
;   ptable_scan.s) or, for unlisted devices, the device base name with
;   .device stripped and A-Z/0-9 uppercased. Name clashes with existing
;   mounts are uniquified (.1/.2) at register time; the registered name
;   is then recorded in pe_MountName, so lsptres shows scanname>realname.

;-- pe_Source values
PES_MBR		= 0
PES_GPT		= 1
PES_RDB		= 2
PES_FLAT	= 3			;superfloppy: whole-disk FAT volume

;-- pe_Flags bit numbers (bset/btst)
PEB_PRESENT	= 0			;entry valid
PEB_BOOTABLE	= 1			;RDB PBFFB_BOOTABLE
PEB_NOMOUNT	= 2			;RDB PBFFB_NOMOUNT: publish, never mount
PEB_MOUNTED	= 3			;a DeviceNode is registered
PEB_INVALID	= 4			;mounted slot, but the inserted card has no such
					;partition. Derived each scan (MOUNTED & !PRESENT
					;while media is in), not stored policy.
PEB_KEEPSTATIC	= 5			;layout v4: keep this entry's static mount on
					;card removal. Stamped by MountPartitions from
					;mc_UnmFlags MCUF_KEEPSTATIC on every entry it
					;walks; meaningful only with pe_BlobPtr = 0
					;(a node this library did not build).
PEB_MOUNTUSED	= 6			;layout v4: a hand mountlist may claim this
					;entry even while another handler serves it
					;(the user's own risk; writes corrupt the
					;volume). Stamped by MountPartitions from
					;mc_UnmFlags MCUF_MOUNTUSED; read by fat95's
					;auto-detect ownership gate.
PEB_SHADOW	= 7			;layout v5: an extra-mount row. A handler
					;that registered over a partition another
					;node already serves gets its own cloned
					;entry (the owner row is never overlaid),
					;so the resource lists every mount. Freed
					;by UnregisterPartition or the teardown.

;-- DosType stamped on FAT partitions (fat95 registers $46415400|n)
DOSTYPE_FAT	= $46415400

;-- fat95's "device-name scheme" dostype: a hotplug node built with this
;   DE_DOSTYPE (and de_LowCyl=0) binds to fat95, auto-detects its partition
;   per inserted card, and takes its partition selector from the node name's
;   trailing digit (CF0/CF1/...). Lets one persistent handler track any
;   card layout. Must match fat95's DEVICE_DOSTYPE_MARKER.
DEVICE_DOSTYPE_MARKER = $464154FF

;--- Resident priorities (RT_PRI) for InitCode ordering -------------------
;
; InitCode runs higher-priority residents first. Reference points (Hyperion
; 47.x): scsi.device runs at prio 10, Kickstart strap runs at prio -60.
;
; Cold-boot order:
;   PRI_PTABLE_LIB    ptable.library RTF_AUTOINIT       must precede consumers
;   PRI_CFD_DEVICE    compactflash.device RTF_AUTOINIT  AddDevice for our unit
;   (scsi.device)                                       prio 10, not ours
;   (pfs3aio ROM module)                                prio 78, registers its
;                                                       FileSysEntry
;   (fat95 ROM module)                                  prio 0, registers
;                                                       FAT\0..\8 plus the
;                                                       $464154FF device-scheme
;                                                       FileSysEntries
;   PRI_CFD_BOOT      compactflash.autoboot RTF_COLDSTART opens ptable.library,
;                                                       calls BootScanPartitions
;
; PRI_CFD_BOOT must run AFTER every ROM filesystem has registered in
; FileSystem.resource (fat95 inits at 0), or the cold act binds no
; handler and the registered nodes never start. -5 keeps it well above
; strap (-60), which is the only hard lower bound (AddBootNode must
; happen before strap).
;
PRI_PTABLE_LIB	equ	22
PRI_CFD_DEVICE	equ	21
PRI_CFD_BOOT	equ	-5
