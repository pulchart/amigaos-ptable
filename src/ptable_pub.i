; ptable.library v2 - public interface
;
; One pipeline: every partition scheme (RDB, MBR, GPT, superfloppy "flat")
; is parsed by this library and PUBLISHED into partition.resource; the act
; stages (cold register, runtime mount/unmount) consume only the resource.
; Include in the library itself and in any consumer (device cold stub,
; mount worker). fat95 and lsptres mirror the PartEntry offsets below.

;--- LVOs (Exec convention: Open/Close/Expunge/Reserved = -6..-24) ---------
;
; BootScanPartitions(deviceName: a1, unit: d0) -> d0 = partitions registered
;   Cold stage; call from an RTF_COLDSTART context (pre-DOS, single task).
;   Scans the device, publishes every partition into partition.resource,
;   loads RDB-carried filesystems into FileSystem.resource, then registers
;   each mountable entry: RDB+bootable via AddBootNode, everything else via
;   AddDosNode(flags=0). System-Startup starts the handlers (steps 3-8).
;   Adds the synthetic ConfigDev (boot menu) when anything was registered.
;
; ScanPartitions(deviceName: a1, unit: d0)   -> d0 = partitions published
;   Publish only, no mounting. Exec-only; callable from any task context.
;
; MountPartitions(deviceName: a1, unit: d0, cfg: a0)  -> d0 = partitions mounted
;   Runtime act; CALL FROM A PROCESS. AddDosNode(ADNF_STARTPROC) every
;   entry that is !MOUNTED !NOMOUNT for the device+unit. cfg (a MountCfg, or 0
;   for cold-boot defaults) supplies the global Flags + CONTROL and per-dostype
;   overrides; each entry resolves its Flags+Control by pe_DosType, the node gets
;   fssm_Flags + de_Control stamped, and the resolved values are recorded in
;   pe_MountFlags / pe_Control.
;
; UnmountPartitions(deviceName: a1, unit: d0, prefixList: a0) -> d0 = removed
;   Runtime teardown; CALL FROM A PROCESS. prefixList = 0: ACTION_DIE +
;   RemDosEntry + free every mounted entry for the device+unit (published-only
;   records are dropped). prefixList != 0 (0-terminated longwords of dostype
;   high 3 bytes, e.g. $50465300 'PFS'): tear down only entries whose
;   pe_DosType matches; every other matched entry is marked absent
;   (PEB_PRESENT cleared, handler kept).

;--- MountCfg (cfd -> MountPartitions in a0; 0 = cold-boot defaults) -------
;
; Global Flags + CONTROL plus a per-dostype override table. ptable resolves
; each entry by (pe_DosType & $FFFFFF00) against the overrides, falling back to
; the global value. Strings are NUL-terminated C strings owned by the caller
; for the duration of the call (ptable copies what it retains).
;
mc_Flags	= 0			;ULONG global fssm_Flags
mc_Control	= 4			;APTR  global CONTROL C-string (0 = none)
mc_Overrides	= 8			;APTR  override table (0 = none)
mc_Sizeof	= 12
;
; Override row (array terminated by ovr_Prefix = 0):
ovr_Prefix	= 0			;ULONG dostype high 3 bytes ('DOS\0' etc); 0 = end
ovr_Flags	= 4			;ULONG override fssm_Flags
ovr_HasFlags	= 8			;UBYTE 1 = FLAGS_<fs> present (else use global)
;		  9..11			;(pad)
ovr_Control	= 12			;APTR  override CONTROL C-string (0 = use global)
ovr_Sizeof	= 16

_LVOBootScanPartitions	= -30
_LVOScanPartitions	= -36
_LVOMountPartitions	= -42
_LVOUnmountPartitions	= -48
_LVORegisterPartition	= -54
_LVOMarkAbsent		= -60
;
; RegisterPartition(deviceName: a1, unit: d0, startLBA: d1, blockCount: d2,
;               nameBSTR: a0, devNode: a2, flags: d3, control: d4)
;                                                 -> d0 = 1 updated / 0 not found
;   Overlay a real mount onto an already-published entry: a handler that
;   serves a volume calls this so the resource shows the volume's real DOS
;   name (dn_Name) and MOUNTED state instead of the synthesized scan name.
;   flags + control (d4 = APTR to a BSTR, 0 = none) are the values the handler
;   actually opened the device with; they are recorded in pe_MountFlags /
;   pe_Control so lsptres reflects the live mount on every path (including the
;   persistent device-dostype handler). Matches by device+unit+startLBA.
;   Exec-only.
;
; MarkAbsent(deviceName: a1, unit: d0)            -> d0 = count cleared
;   Card removed: clear PEB_PRESENT on every entry for device+unit, keeping
;   PEB_MOUNTED, pe_DevNode, the DOS node and the handler in memory (native
;   removable-media model). The handler ejects its volume via the device's
;   disk-change notify; a later ScanPartitions re-sets PEB_PRESENT on
;   reinsert. The keep-everything detach path; UnmountPartitions with a
;   prefixList is the selective-teardown alternative. Exec-only.

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
; Writers (the four LVOs) hold ptr_Lock for their whole run. Read-only
; consumers walk ptr_PartList under Forbid() or take ptr_Lock themselves.
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

PTR_LAYOUT_V	= 2			;bump on every appended field

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
;		  246..259		;reserved for appended fields (zeroed)
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
;            <PPP><unit-letter><partition-number>
;            PPP    3-char device prefix (see below)
;            unit   'A'+unit  (A = unit 0, B = unit 1, ...)
;            part   decimal partition number, 1-based
;            e.g. compactflash.device unit 0 -> CFDA1 CFDA2 CFDA3
;                 scsi.device         unit 0 -> SCSA1 SCSA2 ...
;   The 3-char prefix comes from a known-device abbreviation table
;   (compactflash.device -> CFD; extend s_devAbbrevTable in
;   ptable_scan.s) or, for unlisted devices, the first three letters
;   of the device name uppercased. Name clashes with existing mounts
;   are uniquified (.1/.2) at register time.

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

;-- DosType stamped on FAT partitions (fat95 registers $46415400|n)
DOSTYPE_FAT	= $46415400

;-- fat95's "device-name scheme" dostype: a hotplug node built with this
;   DE_DOSTYPE (and de_LowCyl=0) binds to fat95, auto-detects its partition
;   per inserted card, and takes its partition selector from the node name's
;   trailing digit (CFa0/CFa1/...). Lets one persistent handler track any
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
;                                                       FAT\0..\8 FileSysEntries
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
