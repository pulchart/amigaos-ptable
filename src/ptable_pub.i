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
;   each mountable RDB entry: bootable via AddBootNode, the rest via
;   AddDosNode(flags=0); MBR/GPT/flat entries stay published for a DOS-time
;   consumer. System-Startup starts the handlers (steps 3-8).
;   Adds the synthetic ConfigDev (boot menu) when anything was registered.
;
; ScanPartitions(deviceName: a1, unit: d0)   -> d0 = partitions newly published
;   Publish only, no mounting. Exec-only; callable from any task context.
;
; MountPartitions(deviceName: a1, unit: d0, cfg: a0)  -> d0 = partitions mounted
;   Runtime act; CALL FROM A PROCESS. AddDosNode(ADNF_STARTPROC) every
;   entry that is !MOUNTED !NOMOUNT for the device+unit. cfg (a MountCfg, or 0
;   for cold-boot defaults) supplies the global Flags + CONTROL and per-dostype
;   overrides; each entry resolves its Flags+Control by pe_DosType, the node gets
;   fssm_Flags + de_Control stamped, and the resolved values are recorded in
;   pe_MountFlags / pe_Control. mc_NodeDosType / mc_NodeHandler choose the
;   filesystem for a synthesized-envec partition; the DosType the node ends up
;   with is recorded in pe_NodeDosType.
;
; UnmountPartitions(deviceName: a1, unit: d0, prefixList: a0) -> d0 = torn down
;   Runtime teardown; CALL FROM A PROCESS. prefixList = 0: ACTION_DIE +
;   RemDosEntry + free every mounted entry for the device+unit (published-only
;   records are dropped). prefixList != 0 (0-terminated longwords of dostype
;   high 3 bytes, e.g. $50465300 'PFS'): tear down only entries whose
;   pe_DosType matches; every other matched entry is marked absent
;   (PEB_PRESENT cleared, handler kept).
;   Static-mount exemption: an entry whose DOS node this library did not
;   build (pe_BlobPtr = 0, i.e. a hand-mounted DOSDriver claimed via
;   RegisterPartition or adopted by the mount-time name reuse) AND whose
;   PEB_KEEPSTATIC bit is set is exempt from both modes: not torn down,
;   only marked absent; removing the user's node is then the user's call.
;   The bit is stamped by MountPartitions from mc_UnmFlags, so the policy
;   lives in the resource and lsptres shows it (S vs s in its flag
;   picture); a policy change takes effect on the next mount pass.

;--- MountCfg (-> MountPartitions in a0; 0 = cold-boot defaults) -----------
;
; Global Flags + CONTROL plus a per-dostype override table. ptable resolves
; each entry by (pe_DosType & $FFFFFF00) against the overrides, falling back to
; the global value. Strings are NUL-terminated C strings owned by the caller
; for the duration of the call (ptable copies what it retains).
;
; mc_NodeDosType / mc_NodeHandler let the caller decide which filesystem serves
; a partition this library synthesized an envec for, i.e. one that came from an
; MBR, GPT or flat (whole-disk FAT) card rather than from an RDB. They apply to
; FAT-family entries only; an RDB entry keeps the DosType and the geometry
; recorded on the card.
;
mc_Flags	= 0			;ULONG global fssm_Flags
mc_Control	= 4			;APTR  global CONTROL C-string (0 = none)
mc_Overrides	= 8			;APTR  override table (0 = none)
mc_NodeDosType	= 12			;ULONG DosType to stamp on the node instead of
					;the one the scan chose. Naming one also fixes
					;the node's window to that partition's own block
					;range: a handler told to use a specific DosType
					;is not one auto-detecting its own partition.
					;0 = leave the envec exactly as scanned.
mc_NodeHandler	= 16			;APTR  handler path C-string, e.g. "L:Something",
					;used ONLY when no FileSysEntry matches the
					;node's DosType. 0 = FileSystem.resource only.
mc_Size		= 20			;ULONG the caller's mc_Sizeof. MountCfg's
					;de_TableSize: a field appended in a later
					;release is read only when the caller's
					;declared size covers it, so the struct grows
					;by appending a field and bumping mc_Sizeof.
					;The 2.0 fields above are baseline and are
					;always read.
mc_UnmFlags	= 24			;ULONG policy bits (MCUF_*), read only when
					;mc_Size >= 28. MountPartitions stamps them
					;into the PEB_ policy bits on every entry it
					;walks for the device+unit, so the policy
					;becomes resource state that UnmountPartitions,
					;handlers and lsptres all read.
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
; Keep ovr_Sizeof as it is. The library strides this table with its OWN idea of
; the row size, so growing the row desynchronises a caller built against a
; different header. New settings go in the mc_ block above, behind mc_Size.

_LVOBootScanPartitions	= -30
_LVOScanPartitions	= -36
_LVOMountPartitions	= -42
_LVOUnmountPartitions	= -48
_LVORegisterPartition	= -54
_LVOMarkAbsent		= -60
_LVOUnregisterPartition	= -66
;
; RegisterPartition(deviceName: a1, unit: d0, startLBA: d1, blockCount: d2,
;               nameBSTR: a0, devNode: a2, flags: d3, control: d4,
;               nodeDosType: d5)                  -> d0 = 1 updated / 0 not found
;   Overlay a real mount onto an already-published entry: a handler that
;   serves a volume calls this so the resource shows the volume's real DOS
;   name (dn_Name) and MOUNTED state instead of the synthesized scan name.
;   nodeDosType is the DosType the handler mounted with (-> pe_NodeDosType,
;   0 = unknown). Register inputs cannot be gated by a declared size the way
;   mc_ fields are, so a future input here means a new LVO.
;   flags + control (d4 = APTR to a BSTR, 0 = none) are the values the handler
;   actually opened the device with; they are recorded in pe_MountFlags /
;   pe_Control so lsptres reflects the live mount on every path (including the
;   persistent device-dostype handler). Matches by device+unit+startLBA.
;   An entry MOUNTED by a different node is refused (d0 = 0): overlaying it
;   would bless a second handler on a served partition and desynchronise the
;   pe_DevNode/pe_BlobPtr teardown pairing. Re-registering the entry's own
;   node (rebind) succeeds. Exec-only.
;
; UnregisterPartition(deviceName: a1, unit: d0, startLBA: d1, devNode: a2)
;                                                  -> d0 = 1 cleared / 0 no-op
;   Inverse of RegisterPartition, for a handler that leaves voluntarily
;   (its ACTION_DIE was accepted outside a ptable teardown): clears
;   PEB_MOUNTED/pe_DevNode/pe_MountName and the recorded mount values, so
;   the entry returns to published-only and the partition is the
;   automount's again. Only the entry's own registrant may clear it
;   (pe_DevNode must equal devNode). Attempts PTR_Lock like MarkAbsent
;   and skips when it is busy: a ptable teardown then owns the entry and
;   frees it itself. Exec-only.
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
; Writers (every LVO; MarkAbsent only attempts the lock and skips when it is
; busy) hold ptr_Lock for their whole run. Read-only
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

PTR_LAYOUT_V	= 4			;bump on every appended field (or newly
					;defined pe_Flags bit); v4 = PEB_KEEPSTATIC

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
pe_NodeDosType	= 248			;ULONG DosType actually stamped into the node's
					;DosEnvec (layout 3). NOT pe_DosType: that stays
					;the DETECTED filesystem, so the Flags/CONTROL/
					;UNMOUNT prefix matching keeps working, while the
					;node may be mounted as whatever DosType the
					;caller asked for in mc_NodeDosType.
					;Resolved per mount, or recorded by
					;RegisterPartition; 0 until the entry is mounted.
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
