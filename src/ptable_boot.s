;===========================================================
; ptable_boot.s - BootScanPartitions entry, BootCtx machinery, device IO
;
; Device-agnostic: takes a device name and unit from the caller and
; opens that device. BootScanPartitions is the cold stage of the unified
; pipeline: scan + publish everything (ptable_scan.s), then register
; every mountable entry (ptable_act.s cold act) so System-Startup
; starts the handlers (steps 3-8 of the boot sequence).
;
; Register conventions inside this block:
;   a4 = &BootCtx (allocated on entry, freed on exit)
;   a5 = ExecBase (cached from RDBL_ExecBase(LibBase))
; a6 is repeatedly loaded with ExecBase / ExpansionBase /
; DosBase / FileSystem.resource base before each jsr.
;===========================================================

;--- from expansion.library --------------------------------
AddBootNode	= -36
AddConfigDev	= -30
AddDosNode	= -150

;--- ConfigDev layout (libraries/configvars.i) -------------
;   Only the fields actually written by the synthetic ConfigDev
;   below are defined here; full layout lives in NDK.
CD_NODE_TYPE	= 8
CD_NODE_NAME	= 10
CD_ER_TYPE	= 16
CD_ER_PRODUCT	= 17
CD_ER_MANUF	= 20
CD_ER_SERIAL	= 22
CD_ER_RESERVED0C = 28
CD_BOARDADDR	= 32
CD_BOARDSIZE	= 36
CD_SIZEOF	= 68

NT_CONFIGDEV	= 20
ERTF_DIAGVALID	= $10

;--- from dos.library --------------------------------------
DOS_Delay	= -198

;--- Rigid Disk Block / Partition / FSHD / LSEG ------------
;   Only the fields actually read by the walkers below are
;   defined; *_ID / *_ChkSum / *_SummedLongs are referred to by
;   the RDSK/PART/FSHD/LSEG signature longs (RDSK_ID, ...).
RDB_LOCATION_LIMIT = 16
RDB_BLOCK_BYTES	= 512

rdb_SummedLongs	= 4
rdb_PartitionList = 28
rdb_FileSysHeaderList = 32

RDSK_ID		= $5244534B		;'RDSK'

pb_Next		= 16
pb_Flags	= 20
pb_DriveName	= 36
pb_Environment	= 128

PART_ID		= $50415254		;'PART'

;-- pb_Flags bit numbers (used with btst)
PBFFB_BOOTABLE	= 0
PBFFB_NOMOUNT	= 1

fhb_Next	= 16
fhb_DosType	= 32
fhb_Version	= 36
fhb_PatchFlags	= 40
fhb_Type	= 44
fhb_Task	= 48
fhb_Lock	= 52
fhb_Handler	= 56
fhb_StackSize	= 60
fhb_Priority	= 64
fhb_Startup	= 68
fhb_SegListBlocks = 72
fhb_GlobalVec	= 76

FSHD_ID		= $46534844		;'FSHD'

lsb_Next	= 16
lsb_LoadData	= 20

LSEG_ID		= $4C534547		;'LSEG'

DE_BOOTPRI	= 15
DE_DOSTYPE	= 16
DE_BOOTBLOCKS	= 19

fsr_Creator	= 14
fsr_FileSysEntries = 18
fsr_Sizeof	= 32

fse_DosType	= 14
fse_Version	= 18
fse_PatchFlags	= 22
fse_Type	= 26
fse_Task	= 30
fse_Lock	= 34
fse_Handler	= 38
fse_StackSize	= 42
fse_Priority	= 46
fse_Startup	= 50
fse_SegList	= 54
fse_GlobalVec	= 58
fse_Sizeof	= 62

;--- AmigaDOS hunk format (used by rdb_hunk.s) -------------
HUNK_UNIT	= $000003E7
HUNK_NAME	= $000003E8
HUNK_CODE	= $000003E9
HUNK_DATA	= $000003EA
HUNK_BSS	= $000003EB
HUNK_RELOC32	= $000003EC
HUNK_SYMBOL	= $000003F0
HUNK_DEBUG	= $000003F1
HUNK_END	= $000003F2
HUNK_HEADER	= $000003F3
HUNK_OVERLAY	= $000003F5
HUNK_BREAK	= $000003F6
HUNK_RELOC32SHORT = $000003FC

;--- DeviceNode field offsets (for _bootPatchDNfromFSE) ---
dn_Type		= 4
dn_Task		= 8
dn_Lock		= 12
dn_Handler	= 16
dn_StackSize	= 20
dn_Priority	= 24
dn_Startup	= 28
dn_SegList	= 32
dn_GlobVec	= 36
dn_Name		= 40

;--- shared dos/exec pieces used by the scan + act stages ---
AddTail		= -246			;exec (entry publish order)

;-- dos.library LVOs (runtime acts only; never called pre-DOS)
LockDosList	= -654
UnLockDosList	= -660
RemDosEntry	= -672
NextDosEntry	= -690

;-- exec task/message LVOs for the ACTION_DIE round-trip
Wait		= -318
PutMsg		= -366
GetMsg		= -372

ADNF_STARTPROC	= 1
ACTION_DIE	= 5
PAD_POLL_MAX	= 30			;ACTION_DIE death-poll tries (x100 ms = 3 s)
LDF_WRITE	= 2
LDF_DEVICES	= 4

;-- struct Process / DosList / DosPacket (subset)
TC_SIZE		= 92
pr_MsgPort	= TC_SIZE		;Process: pr_Task then pr_MsgPort
dol_Task	= 8			;DosList/DeviceNode handler process
dp_Link		= 0
dp_Port		= 4
dp_Type		= 8
SP_SIZEOF	= 68			;MN_SIZE(20) + dp_SIZEOF(48)

;-- DosEnvec longword indexes (DE_BOOTPRI/DE_DOSTYPE defined above)
DE_TableSize	= 0
DE_SizeBlock	= 1
DE_SecOrg	= 2
DE_Surfaces	= 3
DE_SectorPerBlk	= 4
DE_BlocksPerTrk	= 5
DE_Reserved	= 6
DE_PreAlloc	= 7
DE_Interleave	= 8
DE_LowCyl	= 9
DE_HighCyl	= 10
DE_NumBuffers	= 11
DE_BufMemType	= 12
DE_MaxTransfer	= 13
DE_Mask		= 14

;-- debug trace helpers shared by the scan/act/runtime stages.
;   PTMSG label : print a string, preserve all registers.
;   PTNUM label : print "label <d0 hex8>" + newline, preserve d0.
	ifd	DEBUG
PTMSG	macro
	movem.l	d0/a0,-(sp)
	lea	\1(pc),a0
	bsr	_bootDebug
	movem.l	(sp)+,d0/a0
	endm
PTNUM	macro
	move.l	d0,-(sp)
	lea	\1(pc),a0
	bsr	_bootDebug
	move.l	(sp),d0
	bsr	_bootDebugHex8
	lea	dbg_boot_nl(pc),a0
	bsr	_bootDebug
	move.l	(sp)+,d0
	endm
;   PTDEC label : print "label <d0 decimal>" + newline, preserve d0.
PTDEC	macro
	move.l	d0,-(sp)
	lea	\1(pc),a0
	bsr	_bootDebug
	move.l	(sp),d0
	bsr	_bootDebugDec32
	lea	dbg_boot_nl(pc),a0
	bsr	_bootDebug
	move.l	(sp)+,d0
	endm
	else
PTMSG	macro
	endm
PTNUM	macro
	endm
PTDEC	macro
	endm
	endc

;===========================================================
; BootCtx layout (one AllocMem on BootScanPartitions entry):
;
;   offset  size  field
;   ------  ----  --------------------------------------------
;       0     4   BC_ExecBase     cached ExecBase
;       4     4   BC_ExpBase      expansion.library base
;       8     4   BC_DosBase      dos.library base (may be 0)
;      12     4   BC_Unit         unit number passed by caller
;      16     4   BC_BlockBuf     -> trailing 512B buffer
;      20     4   BC_FSResource   FileSystem.resource (lazy)
;      24     1   BC_DevOpen      1 if OpenDevice succeeded
;      25     1   BC_SigOK        1 if reply-port signal alloc'd
;      26     1   BC_HaveNodes    1 if any AddBootNode/AddDosNode ran
;      27     1   BC_PartCount    count of partitions registered
;      28    34   BC_DevMsgPort
;      62    56   BC_DevIOReq
;     118     2   (pad to long)
;     120     4   BC_ConfigDev    synthetic ConfigDev (0 = none)
;     124     4   BC_DevName      caller's device name string
;     128     4   BC_DevNameBSTR  cached BSTR(BPTR) of BC_DevName
;                                 for fssm_Device (0 = alloc failed,
;                                 _actBuildBlob then skips)
;     132   512   block buffer (BC_BlockBuf points here)

BC_ExecBase	= 0
BC_ExpBase	= 4
BC_DosBase	= 8
BC_Unit		= 12
BC_BlockBuf	= 16
BC_FSResource	= 20
BC_DevOpen	= 24
BC_SigOK	= 25
BC_HaveNodes	= 26
BC_PartCount	= 27
BC_DevMsgPort	= 28
BC_DevIOReq	= 62
BC_ReadMode	= 118		;cached read method (0 = not yet probed)
BC_ConfigDev	= 120
BC_DevName	= 124
BC_DevNameBSTR	= 128
BC_UnmountPrefixes = 132	;ptr to 0-terminated dostype-prefix list (UnmountPartitions); 0 = all
BC_MountCfg	= 136		;APTR MountCfg (MountPartitions); 0 = cold-boot defaults
BC_Sizeof	= 140

BC_BUF_BYTES	= 512

;--- DeviceNode blob layout (built by _actBuildBlob) ---
DN_FSSM_OFF	= 44
DN_ENVEC_OFF	= 60
DN_BSTR_OFF	= 144
DN_CTRL_OFF	= 176		;32-byte CONTROL BSTR (de_Control points here)
DN_BLOB_SIZE	= 208

;===========================================================
; Constants: ROM strings used during scan
;===========================================================
ExpansionName:
	dc.b	"expansion.library",0
DosName:
	dc.b	"dos.library",0
FileSysResName:
	dc.b	"FileSystem.resource",0
	even
;-- "ptable.library" is shared with the LN_Name string in
;   ptable_lib.s; reuse s_libname(pc) for fsr_Creator and the
;   FileSysEntry LN_Name (see ptable_fs.s).

;--- Debug strings (only emitted in DEBUG builds) ----------
	ifd	DEBUG
dbg_boot_start:
	dc.b	"[PT] cold boot: scanning for partitions",CR,LF,0
dbg_boot_no_card:
	dc.b	"[PT] no card / no media",CR,LF,0
dbg_boot_no_rdb:
	dc.b	"[PT] no partition table (not RDB/MBR/GPT/FAT)",CR,LF,0
dbg_boot_fs_add:
	dc.b	"[PT] + filesystem handler ",0
dbg_boot_part_boot:
	dc.b	"[PT] + boot  ",0
dbg_boot_part_dos:
	dc.b	"[PT] + mount ",0
dbg_boot_part_skip:
	dc.b	"[PT] - skip  ",0
dbg_boot_done:
	dc.b	"[PT] cold boot done, partitions registered: ",0
dbg_boot_exp_fail:
	dc.b	"[PT] error: expansion.library not available",CR,LF,0
dbg_boot_no_mem:
	dc.b	"[PT] error: out of memory",CR,LF,0
dbg_boot_opendev_err:
	dc.b	"[PT] cannot open device, error ",0
dbg_boot_rdsk_found:
	dc.b	"[PT] RDB partition table",CR,LF,0
dbg_boot_nl:
	dc.b	CR,LF,0
dbg_boot_skip_tail:
	dc.b	" (no-mount)",CR,LF,0
dbg_hunk_badid:
	dc.b	"[PT] hunk: bad id $",0
	endc
	even

;===========================================================
; BootScanPartitions
;
; Inputs:
;   a1 = device name (NUL-terminated C-string)
;   d0 = unit number
;   a6 = LibBase
;
; Output:
;   d0 = number of partitions registered (0 = no card / nothing
;        recognised / allocation failure / etc.)
;
; Cold stage of the unified pipeline: publish every partition
; (RDB/MBR/GPT/flat) into partition.resource, then cold-register
; the mountable ones (AddBootNode / AddDosNode flags=0).
;
; Preserves d2-d7/a2-a5/a6
;===========================================================
BootScanPartitions:
	movem.l	d2-d7/a2-a6,-(sp)
	move.l	a1,d6			;d6 = device name
	move.l	d0,d5			;d5 = unit
	move.l	RDBL_ExecBase(a6),a5	;a5 = ExecBase

;-- allocate BootCtx + 512B buffer in one shot
	move.l	#BC_Sizeof+BC_BUF_BYTES,d0
	move.l	#MEMF_PUBLIC+MEMF_CLEAR,d1
	move.l	a5,a6
	jsr	AllocMem(a6)
	tst.l	d0
	bne.s	bs_haveCtx
	ifd	DEBUG
	lea	dbg_boot_no_mem(pc),a0
	bsr	_bootDebug
	endc
	moveq.l	#0,d6			;result count = 0
	bra.w	bs_no_alloc
bs_haveCtx:
	move.l	d0,a4			;a4 = &BootCtx
	move.l	a5,BC_ExecBase(a4)
	move.l	d6,BC_DevName(a4)	;d6 still holds devname
	move.l	d5,BC_Unit(a4)
	lea	BC_Sizeof(a4),a0
	move.l	a0,BC_BlockBuf(a4)
	move.b	#-1,BC_SigOK(a4)	;sentinel: no signal allocated yet

;-- Cache the device-name BSTR once per scan; reused for every
;   partition's fssm_Device. On failure the slot stays 0
;   (BootCtx is MEMF_CLEAR) and _actBuildBlob skips.
	move.l	BC_DevName(a4),a0
	move.l	a5,a6
	bsr	_bootMakeExecBSTR
	move.l	d0,BC_DevNameBSTR(a4)

;-- open expansion.library
	moveq.l	#0,d0
	lea	ExpansionName(pc),a1
	move.l	a5,a6
	jsr	OpenLibrary(a6)
	move.l	d0,BC_ExpBase(a4)
	bne.s	bs_haveExp
	ifd	DEBUG
	lea	dbg_boot_exp_fail(pc),a0
	bsr	_bootDebug
	endc
	bra.w	bs_cleanup
bs_haveExp:

;-- Synthesize a ConfigDev for the device.
;   (The ConfigDev's CD_NODE_NAME points at the caller's device
;   name string so strap renders the early-startup menu against
;   the correct device. ER_TYPE = ERTF_DIAGVALID together with
;   er_Reserved0c -> s_rdb_diag_rom drives the BootPoint flow:
;   strap copies the DiagArea to RAM and calls da_BootPoint,
;   which then runs FindResident("dos.library") + RT_INIT.)
	move.l	a5,a6			;ExecBase
	move.l	#CD_SIZEOF,d0
	move.l	#MEMF_PUBLIC+MEMF_CLEAR,d1
	jsr	AllocMem(a6)
	tst.l	d0
	beq.w	bs_no_cd
	move.l	d0,BC_ConfigDev(a4)
	move.l	d0,a2
	move.b	#NT_CONFIGDEV,CD_NODE_TYPE(a2)
	move.l	BC_DevName(a4),CD_NODE_NAME(a2)
	move.b	#$C0|ERTF_DIAGVALID|4,CD_ER_TYPE(a2)	;Z-II, diag, 512KB
	lea	s_rdb_diag_rom(pc),a0
	move.l	a0,CD_ER_RESERVED0C(a2)
	move.b	#1,CD_ER_PRODUCT(a2)
	move.w	#$FFFF,CD_ER_MANUF(a2)		;no vendor
	move.l	#$52444230,CD_ER_SERIAL(a2)	;'RDB0'
	move.l	#$00A00000,CD_BOARDADDR(a2)	;PCMCIA attributes base
	move.l	#$00080000,CD_BOARDSIZE(a2)	;512 KB
bs_no_cd:

;-- open dos.library; used for Delay() only. OK to be NULL.
	move.l	a5,a6
	moveq.l	#0,d0
	lea	DosName(pc),a1
	jsr	OpenLibrary(a6)
	move.l	d0,BC_DosBase(a4)

	ifd	DEBUG
	lea	dbg_boot_start(pc),a0
	bsr	_bootDebug
	endc

;-- open the requested unit, publish + cold-register, close the unit.
	bsr	_bootOpenUnit
	tst.l	d0
	beq.s	bs_close_unit
	bsr	_partLockRes		;writer lock (uniform; pre-DOS is
	tst.l	d0			;single-threaded anyway)
	beq.s	bs_close_unit
	bsr	_scanRun		;publish all partitions + RDB FSes
	bsr	_actCold		;register the mountable entries
	bsr	_partUnlockRes
bs_close_unit:
	bsr	_bootCloseUnit		;idempotent: handles partial open

;-- Register synthetic ConfigDev with strap (eb_CDevList) so the
;   early-startup boot menu shows the device and the BootPoint
;   fires when the user picks a bootable partition. Guarded:
;   only call when at least one partition was registered.
	tst.b	BC_HaveNodes(a4)
	beq.s	bs_close
	move.l	BC_ConfigDev(a4),d0
	beq.s	bs_close
	move.l	BC_ExpBase(a4),d0
	beq.s	bs_close
	move.l	d0,a6
	move.l	BC_ConfigDev(a4),a0
	jsr	AddConfigDev(a6)

bs_close:
	move.l	BC_ExecBase(a4),a6
	move.l	BC_DosBase(a4),d0
	beq.s	bs_close1
	move.l	d0,a1
	jsr	CloseLibrary(a6)
bs_close1:
	move.l	BC_ExpBase(a4),d0
	beq.s	bs_cleanup
	move.l	d0,a1
	jsr	CloseLibrary(a6)

bs_cleanup:
	moveq.l	#0,d6
	move.b	BC_PartCount(a4),d6	;return value = partitions registered
	ifd	DEBUG
	lea	dbg_boot_done(pc),a0
	bsr	_bootDebug
	move.l	d6,d0
	bsr	_bootDebugDec32
	lea	dbg_boot_nl(pc),a0
	bsr	_bootDebug
	endc
	move.l	a4,a1
	move.l	#BC_Sizeof+BC_BUF_BYTES,d0
	move.l	BC_ExecBase(a4),a6
	jsr	FreeMem(a6)

bs_no_alloc:
	move.l	d6,d0
	movem.l	(sp)+,d2-d7/a2-a6
	rts

;===========================================================
; _bootOpenUnit: OpenDevice + spin on TD_CHANGESTATE.
;
; Input:  a4 = &BootCtx, a5 = ExecBase, BC_Unit / BC_DevName set
; Output: d0 = 1 on success (media present), 0 on failure
;===========================================================
_bootOpenUnit:
	move.l	a5,a6

;-- MsgPort
	sub.l	a1,a1
	jsr	FindTask(a6)
	lea	BC_DevMsgPort(a4),a2
	move.l	d0,MP_SigTask(a2)

	moveq.l	#-1,d0
	jsr	AllocSignal(a6)
	cmp.b	#-1,d0
	bne.s	_bou_sig_ok
	bra.w	_bou_fail
_bou_sig_ok:
	move.b	d0,MP_SigBit(a2)
	move.b	d0,BC_SigOK(a4)
	move.b	#NT_MSGPORT,LN_Type(a2)
	clr.b	MP_Flags(a2)		;PA_SIGNAL = 0
	lea	MP_MsgList(a2),a0
	move.l	a0,(a0)			;INITLIST inline
	addq.l	#4,(a0)
	clr.l	4(a0)
	move.l	a0,8(a0)

;-- IOStdReq
	lea	BC_DevIOReq(a4),a1
	move.b	#NT_MESSAGE,LN_Type(a1)
	move.w	#IO_Sizeof,MN_Length(a1)
	move.l	a2,MN_ReplyPort(a1)

;-- OpenDevice (caller-supplied name + unit)
	move.l	BC_DevName(a4),a0
	move.l	BC_Unit(a4),d0
	moveq.l	#0,d1
	jsr	OpenDevice(a6)
	tst.l	d0
	beq.s	_bou_od_ok
	ifd	DEBUG
	move.l	d0,-(sp)
	lea	dbg_boot_opendev_err(pc),a0
	bsr	_bootDebug
	move.l	(sp)+,d0
	bsr	_bootDebugHex8
	lea	dbg_boot_nl(pc),a0
	bsr	_bootDebug
	endc
	bra.w	_bou_fail
_bou_od_ok:
	move.b	#1,BC_DevOpen(a4)

;-- poll TD_CHANGESTATE up to 5s for slow card spin-up
	moveq.l	#50,d7
_bou_poll:
	lea	BC_DevIOReq(a4),a1
	move.w	#TD_CHANGESTATE,IO_Command(a1)
	clr.l	IO_Actual(a1)
	clr.b	IO_Error(a1)
	jsr	DoIO(a6)
	tst.b	BC_DevIOReq+IO_Error(a4)
	bne.s	_bou_delay
	move.l	BC_DevIOReq+IO_Actual(a4),d0
	beq.s	_bou_ok			;IO_Actual=0 -> media present
_bou_delay:
	bsr	_bootDelay100ms
	subq.w	#1,d7
	bne.s	_bou_poll
	ifd	DEBUG
	lea	dbg_boot_no_card(pc),a0
	bsr	_bootDebug
	endc
	moveq.l	#0,d0
	rts
_bou_ok:
	moveq.l	#1,d0
	rts
_bou_fail:
	moveq.l	#0,d0
	rts

;===========================================================
; _bootCloseUnit: CloseDevice + FreeSignal (idempotent)
;===========================================================
_bootCloseUnit:
	move.l	BC_ExecBase(a4),a6
	tst.b	BC_DevOpen(a4)
	beq.s	_bcu_sig
	lea	BC_DevIOReq(a4),a1
	jsr	CloseDevice(a6)
	clr.b	BC_DevOpen(a4)
_bcu_sig:
	move.b	BC_SigOK(a4),d0
	cmp.b	#-1,d0
	beq.s	_bcu_end
	ext.w	d0
	ext.l	d0
	jsr	FreeSignal(a6)
	move.b	#-1,BC_SigOK(a4)
_bcu_end:
	rts

;===========================================================
; _bootDelay100ms: sleep ~100 ms. Uses dos.library/Delay(5)
; if DosBase is open, otherwise a rough busy-wait (~350k
; simple insns is ~100ms on a 7 MHz 68000).
;===========================================================
_bootDelay100ms:
	move.l	a6,-(sp)
	move.l	BC_DosBase(a4),d0
	beq.s	_bd_busy
	move.l	d0,a6
	moveq.l	#5,d1			;50 Hz * 0.1s = 5 ticks
	jsr	DOS_Delay(a6)
	move.l	(sp)+,a6
	rts
_bd_busy:
	move.l	#150000,d0
_bd_bl:	subq.l	#1,d0
	bne.s	_bd_bl
	move.l	(sp)+,a6
	rts

;===========================================================
; _bootReadBlock: read one 512B block by 32-bit block#.
;
; Input:  d0 = block# (0..16M), a4 = &BootCtx
; Output: d0 = 0 on success, nonzero (IO_Error) otherwise
;
; Wraps _bootReadBytes64 so reads survive partition starts
; that wrap past 4 GiB in 32-bit IO_Offset.
;===========================================================
_bootReadBlock:
	movem.l	d1-d2/a1,-(sp)
	moveq.l	#0,d1			;high32 = 0 (block# always small)
	add.l	d0,d0			;*2 via add.l (faster than lsl.l #1)
	lsl.l	#8,d0			;d0 = block * 512 (low32)
	exg	d0,d1			;d0=high32=0, d1=low32
	move.l	#RDB_BLOCK_BYTES,d2
	move.l	BC_BlockBuf(a4),a1
	bsr	_bootReadBytes64
	movem.l	(sp)+,d1-d2/a1
	rts

;===========================================================
; _bootReadBytes64: read bytes at a 64-bit byte offset.
;
; The read command varies by device: modern drivers (compactflash,
; scsi.device) take NSCMD_TD_READ64, floppy drivers (mfm.device) only
; CMD_READ, and old controllers sit in between. On the first read we
; probe NSCMD_TD_READ64 -> TD_READ64 -> HD_SCSICMD -> CMD_READ, keep the
; first the device accepts (anything but IOERR_NOCMD), and cache it in
; BC_ReadMode for the rest of the scan.
;
; Input : d0.l = high32, d1.l = low32, d2.l = bytes,
;         a1   = destination, a4 = &BootCtx
; Output: d0 = 0 on success, nonzero IO_Error otherwise
;===========================================================
_bootReadBytes64:
	movem.l	d1-d6/a0-a3/a6,-(sp)
	move.l	BC_ExecBase(a4),a6
	move.l	d0,d3			;d3 = high32
	move.l	d1,d4			;d4 = low32
	move.l	d2,d5			;d5 = byte length
	move.l	a1,a3			;a3 = destination

	moveq.l	#0,d0
	move.b	BC_ReadMode(a4),d0
	bne.s	_brb_dispatch		;already probed -> use cached method

;-- probe NSCMD(1) -> TD64(2) -> SCSI(3) -> CMD_READ(4)
	moveq.l	#1,d6			;d6 = trial method
_brb_probe:
	move.l	d6,d0
	bsr	_brb_try		;d0 = IO_Error
	tst.b	d0
	beq.s	_brb_cache		;this method actually read -> use it
	cmp.b	#4,d6
	beq.s	_brb_cache		;CMD_READ is the last resort (cache anyway)
	addq.l	#1,d6
	bra.s	_brb_probe
_brb_cache:
	move.b	d6,BC_ReadMode(a4)
	bra.s	_brb_ret

_brb_dispatch:
	bsr	_brb_try		;d0 = method in, IO_Error out
_brb_ret:
	movem.l	(sp)+,d1-d6/a0-a3/a6
	rts

;-- _brb_try: issue one read with method d0; d3=hi d4=lo d5=len a3=dest
;   a4=ctx a6=ExecBase. Returns d0 = IO_Error.
_brb_try:
	lea	BC_DevIOReq(a4),a0
	clr.b	IO_Error(a0)
	cmp.b	#1,d0
	beq.s	_brt_nscmd
	cmp.b	#2,d0
	beq.s	_brt_td64
	cmp.b	#3,d0
	beq.s	_brt_scsi
;-- method 4: CMD_READ (32-bit byte offset; low32 only)
	move.w	#CMD_READ,IO_Command(a0)
	move.l	d4,IO_Offset(a0)
	move.l	d5,IO_Length(a0)
	move.l	a3,IO_Data(a0)
	bra.s	_brt_doio
_brt_nscmd:
	move.w	#NSCMD_TD_READ64,IO_Command(a0)
	move.l	d3,IO_Actual(a0)	;high 32
	move.l	d4,IO_Offset(a0)	;low  32
	move.l	d5,IO_Length(a0)
	move.l	a3,IO_Data(a0)
	bra.s	_brt_doio
_brt_td64:
	move.w	#TD_READ64,IO_Command(a0)
	move.l	d3,IO_Actual(a0)	;high 32
	move.l	d4,IO_Offset(a0)	;low  32
	move.l	d5,IO_Length(a0)
	move.l	a3,IO_Data(a0)
	bra.s	_brt_doio
_brt_scsi:
	bsr	_brb_scsi10		;builds + issues READ(10)
	bra.s	_brt_err
_brt_doio:
	move.l	a0,a1
	jsr	DoIO(a6)
_brt_err:
	moveq.l	#0,d0
	move.b	BC_DevIOReq+IO_Error(a4),d0
	rts

;-- _brb_scsi10: HD_SCSICMD READ(10). a0 = IOReq, d3=hi d4=lo (byte
;   offset), d5=len, a3=dest, a6=ExecBase. SCSICmd + 10-byte CDB on stack.
;   Preserves d3-d5/a0/a3 (caller's working values); clobbers d0-d1/a1-a2.
_brb_scsi10:
	movem.l	d0-d1/a1-a2,-(sp)
	lea	-48(sp),sp		;scratch: SCSICmd(30) + CDB(10) + pad
	move.l	sp,a2			;a2 = SCSICmd
	lea	scsi_Sizeof(a2),a1	;a1 = CDB (after the struct)
;-- zero the SCSICmd (esp. sense pointer/length -> no autosense write)
	moveq.l	#0,d0
	move.l	d0,0(a2)
	move.l	d0,4(a2)
	move.l	d0,8(a2)
	move.l	d0,12(a2)
	move.l	d0,16(a2)
	move.l	d0,20(a2)
	move.l	d0,24(a2)
	move.l	d0,28(a2)
;-- LBA = byte offset >> 9 (block-aligned); 32-bit reach is plenty
	move.l	d4,d0
	lsr.l	#8,d0
	lsr.l	#1,d0			;d0 = low32 >> 9
	move.l	d3,d1
	lsl.l	#8,d1
	lsl.l	#8,d1
	lsl.l	#7,d1			;d1 = high32 << 23
	or.l	d1,d0			;d0 = LBA (blocks)
;-- length in blocks
	move.l	d5,d1
	lsr.l	#8,d1
	lsr.l	#1,d1			;d1 = len >> 9
;-- build the CDB
	move.b	#$28,(a1)		;READ(10)
	clr.b	1(a1)
	move.b	d0,5(a1)		;LBA big-endian
	lsr.l	#8,d0
	move.b	d0,4(a1)
	lsr.l	#8,d0
	move.b	d0,3(a1)
	lsr.l	#8,d0
	move.b	d0,2(a1)
	clr.b	6(a1)
	move.b	d1,8(a1)		;length (blocks) big-endian
	lsr.l	#8,d1
	move.b	d1,7(a1)
	clr.b	9(a1)
;-- build the SCSICmd
	move.l	a3,scsi_Data(a2)
	move.l	d5,scsi_Length(a2)
	move.l	a1,scsi_Command(a2)
	move.w	#10,scsi_CmdLength(a2)
	move.b	#SCSIF_READ,scsi_Flags(a2)
;-- issue HD_SCSICMD (a0 still holds the IOReq)
	move.w	#HD_SCSICMD,IO_Command(a0)
	move.l	a2,IO_Data(a0)
	move.l	#scsi_Sizeof,IO_Length(a0)
	move.l	a0,a1
	jsr	DoIO(a6)
	lea	48(sp),sp		;free scratch
	movem.l	(sp)+,d0-d1/a1-a2
	rts

;===========================================================
; _bootChecksum: sum of first d1 longs of buffer (a0).
; Returns d0 = 0 if checksum valid, nonzero otherwise.
;===========================================================
_bootChecksum:
	movem.l	d2/a2,-(sp)
	move.l	a0,a2
	moveq.l	#0,d0
	move.l	d1,d2
	subq.l	#1,d2
	bmi.s	_bcs_end
_bcs_loop:
	add.l	(a2)+,d0
	dbra	d2,_bcs_loop
_bcs_end:
	movem.l	(sp)+,d2/a2
	tst.l	d0
	rts


;===========================================================
; _bootMakeExecBSTR: allocate and fill a BSTR copy of a
; NUL-terminated C string for FSSM use. ptable.library is
; device-agnostic so the caller-supplied name has to be
; converted to a BSTR at runtime.
;
; Called once per BootScanPartitions invocation; the result is cached
; in BC_DevNameBSTR and shared across every partition's FSSM.
;
; Input : a0 = NUL-terminated C string, a4 = &BootCtx,
;         a6 = ExecBase
; Output: d0 = BPTR (already >>2) to BSTR, or 0 on failure
;         (Allocation is small and intentionally leaked: it must
;          outlive BootCtx for FSSM consumers to keep using it.
;          Total leak per scan is name_length + 4 bytes.)
;===========================================================
_bootMakeExecBSTR:
	movem.l	d1-d3/a0-a2,-(sp)
	move.l	a0,a1			;a1 = src

;-- count length (clamped to 255 for BSTR)
	moveq.l	#0,d2
_bmb_cnt:
	tst.b	(a1)+
	beq.s	_bmb_cnt_done
	addq.l	#1,d2
	cmp.l	#255,d2
	blo.s	_bmb_cnt
_bmb_cnt_done:

;-- alloc round_up(d2 + 1, 4) bytes; pad to longword for BSTR
	move.l	d2,d0
	addq.l	#1,d0			;include length byte
	addq.l	#3,d0
	and.l	#~3,d0
	move.l	#MEMF_PUBLIC+MEMF_CLEAR,d1
	jsr	AllocMem(a6)
	tst.l	d0
	beq.s	_bmb_fail
	move.l	d0,a1			;a1 = BSTR base
	move.b	d2,(a1)+		;length byte
;-- restore saved src ptr from stack: movem.l layout (low->high) is
;-- d1,d2,d3,a0,a1,a2, so the saved a0 lives at 12(sp), not (sp).
	move.l	12(sp),a0		;src ptr (saved a0)
	move.l	d2,d3			;copy d2 chars
	tst.l	d3
	beq.s	_bmb_done
_bmb_cp:
	move.b	(a0)+,(a1)+
	subq.l	#1,d3
	bne.s	_bmb_cp
_bmb_done:
;-- d0 already holds the BSTR base from AllocMem; turn it into a
;-- BPTR in place. movem.l restore touches d1-d3/a0-a2 only, so
;-- d0 carries the result through to the caller.
	lsr.l	#2,d0			;BPTR
	movem.l	(sp)+,d1-d3/a0-a2
	rts
_bmb_fail:
	movem.l	(sp)+,d1-d3/a0-a2
	moveq.l	#0,d0
	rts

;===========================================================
; _bootDedupName: ensure the candidate drive name (BSTR at
; DN_BSTR_OFF in the DN blob) is unique on expansion.library's
; eb_MountList. Mirrors commonly used rule by .device(s):
; if the name already exists, append ".n" (.1, .2, ...) and, if
; a name ending ".n" is also present, bump to ".n+1" and rescan
; from the top.
;
; Input : a4 = &BootCtx, a5 = DN blob (name BSTR at DN_BSTR_OFF)
; Output: BSTR at DN_BSTR_OFF mutated in place if a clash was hit
; Preserves a4/a5/a6/d7 (the caller relies on a5/d7).
;===========================================================
_bootDedupName:
	movem.l	d0-d6/a0-a3,-(sp)
	move.l	BC_ExpBase(a4),a3	;a3 = ExpansionBase
	move.l	a3,d0
	beq.s	_bdn_ret		;no exp.lib -> nothing to check

	lea	DN_BSTR_OFF(a5),a0
	moveq.l	#0,d5
	move.b	(a0),d5			;d5 = original base char count
	moveq.l	#0,d4			;d4 = suffix counter (0 = bare name)

_bdn_retry:
;-- walk eb_MountList (LH at offset 74); entries are BootNodes.
	lea	74(a3),a0		;a0 = &eb_MountList
	move.l	(a0),a1			;a1 = first node (lh_Head)
_bdn_walk:
	move.l	(a1),d0			;ln_Succ
	beq.s	_bdn_unique		;tail sentinel -> name is unique
	move.l	16(a1),a2		;bn_DeviceNode
	move.l	a2,d0
	beq.s	_bdn_next		;NULL device node
	move.l	40(a2),d0		;dn_Name (BPTR)
	beq.s	_bdn_next		;NULL name
	lsl.l	#2,d0
	move.l	d0,a2			;a2 = existing name BSTR
	lea	DN_BSTR_OFF(a5),a0	;a0 = candidate BSTR
	bsr	_bootBStrEqualCI	;Z = equal
	beq.s	_bdn_dup
_bdn_next:
	move.l	(a1),a1			;a1 = ln_Succ
	bra.s	_bdn_walk

_bdn_dup:
	cmp.l	#9999,d4		;defensive cap on suffix value
	bhs.s	_bdn_unique
	addq.l	#1,d4
	bsr	_bootApplySuffix
	bra.s	_bdn_retry

_bdn_unique:
_bdn_ret:
	movem.l	(sp)+,d0-d6/a0-a3
	rts

;===========================================================
; _bootFindNode: find an existing DeviceNode by name on the same
; eb_MountList that _bootDedupName walks (so it sees both cold- and
; runtime-added cfd slot nodes). Used by _actMount to REUSE a persistent
; slot node instead of adding a duplicate (which would .N-suffix).
; In : a4 = &BootCtx (BC_ExpBase), a0 = wanted name BSTR
; Out: d0 = DeviceNode ptr, or 0 if no node with that name exists
; Preserves a4/a5/a6.
;===========================================================
_bootFindNode:
	movem.l	d1/a0-a3,-(sp)
	move.l	a0,a3			;a3 = wanted name BSTR
	move.l	BC_ExpBase(a4),a1
	move.l	a1,d0
	beq.s	_bfn_no			;no exp.lib
	lea	74(a1),a0
	move.l	(a0),a1			;a1 = first BootNode (lh_Head)
_bfn_walk:
	move.l	(a1),d0			;ln_Succ
	beq.s	_bfn_no			;tail -> not found
	move.l	16(a1),d1		;d1 = bn_DeviceNode
	beq.s	_bfn_next
	move.l	d1,a2
	move.l	40(a2),d0		;dn_Name (BPTR)
	beq.s	_bfn_next
	lsl.l	#2,d0
	move.l	d0,a0			;a0 = existing name BSTR (arg A)
	move.l	a3,a2			;a2 = wanted name BSTR (arg B)
	bsr	_bootBStrEqualCI	;Z = equal; preserves a0/a2/d1-d3
	bne.s	_bfn_next		;name differs -> next
;-- name matches: reuse only if this node's FileSysStartupMsg is OUR
;   device+unit; a foreign same-named device (e.g. scsi.device SDH0)
;   must not be aliased, so keep walking past it.
	move.l	d1,a2			;a2 = matched DeviceNode
	move.l	28(a2),d0		;dn_Startup (BPTR FSSM)
	beq.s	_bfn_next		;no startup -> not ours
	lsl.l	#2,d0
	move.l	d0,a2			;a2 = FSSM
	move.l	BC_Unit(a4),d0
	cmp.l	(a2),d0			;fssm_Unit
	bne.s	_bfn_next
	move.l	4(a2),d0		;fssm_Device (BPTR BSTR)
	beq.s	_bfn_next
	lsl.l	#2,d0
	move.l	d0,a0			;a0 = node device BSTR (arg A)
	move.l	BC_DevNameBSTR(a4),a2	;a2 = our device BSTR (arg B)
	bsr	_bootBStrEqualCI	;Z = equal; preserves a0/a2/d1-d3
	bne.s	_bfn_next		;foreign device -> skip
	bra.s	_bfn_hit		;owned match -> reuse
_bfn_next:
	move.l	(a1),a1			;a1 = ln_Succ
	bra.s	_bfn_walk
_bfn_hit:
	move.l	d1,d0			;d0 = DeviceNode
	bra.s	_bfn_done
_bfn_no:
	moveq.l	#0,d0
_bfn_done:
	movem.l	(sp)+,d1/a0-a3
	rts

;===========================================================
; _bootUnlinkBootNode: drop the eb_MountList BootNode that points at a
; given DeviceNode. Cold-boot mounts register via AddBootNode, which links
; a BootNode onto expansion.library's eb_MountList; teardown frees the DN
; blob (the dn_Name BSTR lives inside it), so the BootNode must be unlinked
; first or its stale bn_DeviceNode->dn_Name faults the next list walk
; (_bootFindNode/_bootDedupName and expansion's own AddDosNode).
; The BootNode struct itself is NOT freed (expansion-allocated, size not
; reliably known); the leak is one-time and bounded - only the single
; cold-boot BootNode ever exists, since re-mounts use AddDosNode which adds
; nothing to eb_MountList.
; In : a4 = &BootCtx (BC_ExpBase), d0 = DeviceNode to unlink, a5 = ExecBase
; Out: d0 = 1 the list was checked (node removed or not present),
;      d0 = 0 BC_ExpBase missing -> caller must NOT free the DN blob
;      (a dangling bn_DeviceNode is worse than a bounded leak).
; Preserves d1-d7/a0-a6.
;===========================================================
_bootUnlinkBootNode:
	movem.l	d1/a0-a3/a6,-(sp)
	move.l	d0,d1			;d1 = target DeviceNode
	beq.s	_bubn_ok		;nothing to unlink -> fine
	move.l	BC_ExpBase(a4),a3	;a3 = ExpansionBase
	move.l	a3,d0
	beq.s	_bubn_ret		;no exp.lib -> d0 = 0
	move.l	a5,a6
	jsr	Forbid(a6)
	move.l	74(a3),a1		;a1 = eb_MountList lh_Head (first BootNode)
_bubn_walk:
	move.l	(a1),d0			;ln_Succ
	beq.s	_bubn_perm		;tail sentinel -> not found
	cmp.l	16(a1),d1		;bn_DeviceNode == target?
	beq.s	_bubn_hit
	move.l	(a1),a1			;a1 = ln_Succ
	bra.s	_bubn_walk
_bubn_hit:
	jsr	Remove(a6)		;a1 = the BootNode
_bubn_perm:
	jsr	Permit(a6)
_bubn_ok:
	moveq.l	#1,d0
_bubn_ret:
	movem.l	(sp)+,d1/a0-a3/a6
	rts

;===========================================================
; _bootApplySuffix: rewrite the name BSTR in place as
; "<base>.<n>". The base chars stay at DN_BSTR_OFF+1; the dot
; and digits are written strictly to their right, so the base
; prefix we re-read on each bump is never corrupted. If the
; result would exceed the 31-char the base is truncated (the
; suffix is kept, since it guarantees uniqueness).
;
; Input : a5 = DN blob, d4 = suffix value (>=1), d5 = base len
; Preserves all registers.
;===========================================================
_bootApplySuffix:
	movem.l	d0-d3/a0-a2,-(sp)
	lea	-8(sp),sp		;8-byte digit scratch
	move.l	sp,a2			;a2 = scratch base
	move.l	a2,a0			;a0 = scratch write ptr
	moveq.l	#0,d1			;digit count
	move.l	d4,d0			;value to convert
_bas_div:
	divu.w	#10,d0			;d0 = [rem:quot]
	move.w	d0,d2			;d2.w = quotient
	clr.w	d0
	swap	d0			;d0.w = remainder
	add.b	#'0',d0
	move.b	d0,(a0)+		;store digit (least significant first)
	addq.l	#1,d1
	moveq.l	#0,d0
	move.w	d2,d0			;d0 = quotient (zero-extended)
	tst.w	d0
	bne.s	_bas_div

;-- suffixLen = d1 + 1 (the dot); clamp kept base so total <= 31
	move.l	d1,d3
	addq.l	#1,d3			;d3 = suffix length
	move.l	d5,d2			;d2 = kept base length
	move.l	d2,d0
	add.l	d3,d0
	cmp.l	#31,d0
	bls.s	_bas_fits
	moveq.l	#31,d2
	sub.l	d3,d2			;keptBase = 31 - suffixLen
_bas_fits:
;-- length byte
	lea	DN_BSTR_OFF(a5),a1
	move.l	d2,d0
	add.l	d3,d0			;total length
	move.b	d0,(a1)
;-- '.' after the kept base
	lea	1(a1),a1
	add.l	d2,a1
	move.b	#'.',(a1)+
;-- digits, most significant first (scratch holds them reversed)
	move.l	a2,a0
	add.l	d1,a0			;a0 -> one past last stored digit
_bas_wr:
	move.b	-(a0),(a1)+
	cmp.l	a2,a0
	bhi.s	_bas_wr

	lea	8(sp),sp		;free scratch
	movem.l	(sp)+,d0-d3/a0-a2
	rts

;===========================================================
; _bootBStrEqualCI: case-insensitive compare of two BSTRs
;
; Input : a0 = BSTR A, a2 = BSTR B
; Output: d0 = 0 and Z set if equal; d0 = 1 and Z clear if not
; Preserves a0/a1/a2 and d1-d3.
;===========================================================
_bootBStrEqualCI:
	movem.l	d1-d3/a0/a2,-(sp)
	moveq.l	#0,d1
	move.b	(a0)+,d1		;len A
	moveq.l	#0,d2
	move.b	(a2)+,d2		;len B
	cmp.b	d1,d2
	bne.s	_bse_ne
	tst.b	d1
	beq.s	_bse_eq			;both empty
_bse_loop:
	move.b	(a0)+,d2
	move.b	(a2)+,d3
	cmp.b	#'a',d2
	blo.s	_bse_d2ok
	cmp.b	#'z',d2
	bhi.s	_bse_d2ok
	sub.b	#$20,d2			;to upper
_bse_d2ok:
	cmp.b	#'a',d3
	blo.s	_bse_d3ok
	cmp.b	#'z',d3
	bhi.s	_bse_d3ok
	sub.b	#$20,d3
_bse_d3ok:
	cmp.b	d2,d3
	bne.s	_bse_ne
	subq.b	#1,d1
	bne.s	_bse_loop
_bse_eq:
	movem.l	(sp)+,d1-d3/a0/a2
	moveq.l	#0,d0			;0 = equal
	tst.l	d0			;set Z
	rts
_bse_ne:
	movem.l	(sp)+,d1-d3/a0/a2
	moveq.l	#1,d0			;nonzero = not equal
	tst.l	d0			;clear Z
	rts

;===========================================================
; Debug helpers (only assembled in DEBUG builds).
; All callable from BootScanPartitions context (a4 = &BootCtx,
; a5 = ExecBase). Use (_AbsExecBase).w so they remain
; callable even when a6 has been temporarily clobbered.
;===========================================================
	ifd	DEBUG
	include	"raw_debug.i"

_bootDebugHex8:
	movem.l	d0-d3/a6,-(sp)
	move.l	(_AbsExecBase).w,a6
	move.l	d0,d2
	moveq.l	#7,d3
_bdhx_lp:
	rol.l	#4,d2
	move.l	d2,d0
	and.l	#$f,d0
	cmp.b	#10,d0
	blt.s	_bdhx_dec
	add.b	#'A'-10,d0
	bra.s	_bdhx_em
_bdhx_dec:
	add.b	#'0',d0
_bdhx_em:
	jsr	RawPutChar(a6)
	dbra	d3,_bdhx_lp
	movem.l	(sp)+,d0-d3/a6
	rts

_bootDebugDosType:
	movem.l	d0-d3/a0/a6,-(sp)
	move.l	(_AbsExecBase).w,a6
	move.l	d0,d2
	moveq.l	#3,d3
_bddt_lp:
	rol.l	#8,d2
	move.l	d2,d0
	and.l	#$ff,d0
	tst.l	d0
	bne.s	_bddt_em
	moveq.l	#'.',d0
_bddt_em:
	jsr	RawPutChar(a6)
	dbra	d3,_bddt_lp
	movem.l	(sp)+,d0-d3/a0/a6
	rts

_bootDebugDecW:
	movem.l	d0-d5/a6,-(sp)
	move.l	(_AbsExecBase).w,a6
	and.l	#$ffff,d0
	sub.l	#8,sp
	move.l	sp,a0
	moveq.l	#4,d3
_bddw_fill:
	move.l	d0,d2
	divu	#10,d2
	move.l	d2,d1
	swap	d1
	and.l	#$ff,d1
	add.b	#'0',d1
	move.b	d1,0(a0,d3.l)
	move.w	d2,d0
	dbra	d3,_bddw_fill
	moveq.l	#0,d3
_bddw_skip:
	cmp.b	#4,d3
	bge.s	_bddw_print
	move.b	0(a0,d3.l),d0
	cmp.b	#'0',d0
	bne.s	_bddw_print
	addq.l	#1,d3
	bra.s	_bddw_skip
_bddw_print:
	move.b	0(a0,d3.l),d0
	and.l	#$ff,d0
	jsr	RawPutChar(a6)
	addq.l	#1,d3
	cmp.b	#5,d3
	blt.s	_bddw_print
	add.l	#8,sp
	movem.l	(sp)+,d0-d5/a6
	rts

_bootDebugVersionNL:
	movem.l	d0-d2/a0/a6,-(sp)
	move.l	(_AbsExecBase).w,a6
	move.l	d0,d2
	moveq.l	#' ',d0
	jsr	RawPutChar(a6)
	moveq.l	#'v',d0
	jsr	RawPutChar(a6)
	move.l	d2,d0
	swap	d0
	and.l	#$ffff,d0
	bsr	_bootDebugDecW
	moveq.l	#'.',d0
	move.l	(_AbsExecBase).w,a6
	jsr	RawPutChar(a6)
	move.l	d2,d0
	and.l	#$ffff,d0
	bsr	_bootDebugDecW
	move.l	(_AbsExecBase).w,a6
	moveq.l	#13,d0
	jsr	RawPutChar(a6)
	moveq.l	#10,d0
	jsr	RawPutChar(a6)
	movem.l	(sp)+,d0-d2/a0/a6
	rts

;-- Print a BSTR (length byte + chars) followed by CR/LF.
;   a0 = BSTR pointer. Length is clamped to 31 so a garbage
;   length byte in a raw RDB block can't run away.
;   Callers: pb_DriveName (skip path, pre-blob) and the deduped
;   name in the DN blob (DN_BSTR_OFF, +boot/+dos paths).
_bootDebugBStr:
	movem.l	d0/d3/a0/a6,-(sp)
	move.l	(_AbsExecBase).w,a6
	moveq.l	#0,d3
	move.b	(a0)+,d3
	cmp.w	#31,d3
	bls.s	_bdbs_ok
	moveq.l	#31,d3
_bdbs_ok:
	subq.l	#1,d3
	bmi.s	_bdbs_nl
_bdbs_lp:
	moveq.l	#0,d0
	move.b	(a0)+,d0
	jsr	RawPutChar(a6)
	dbra	d3,_bdbs_lp
_bdbs_nl:
	moveq.l	#13,d0
	jsr	RawPutChar(a6)
	moveq.l	#10,d0
	jsr	RawPutChar(a6)
	movem.l	(sp)+,d0/d3/a0/a6
	rts

;-- Print a BSTR (length byte + chars), NO trailing CR/LF, so a name can
;   be followed by more text on the same line. a0 = BSTR, clamp 31.
_bootDebugBStrR:
	movem.l	d0/d3/a0/a6,-(sp)
	move.l	(_AbsExecBase).w,a6
	moveq.l	#0,d3
	move.b	(a0)+,d3
	cmp.w	#31,d3
	bls.s	_bdsr_ok
	moveq.l	#31,d3
_bdsr_ok:
	subq.l	#1,d3
	bmi.s	_bdsr_end
_bdsr_lp:
	moveq.l	#0,d0
	move.b	(a0)+,d0
	jsr	RawPutChar(a6)
	dbra	d3,_bdsr_lp
_bdsr_end:
	movem.l	(sp)+,d0/d3/a0/a6
	rts

;-- Print d0.l as unsigned decimal (full 32-bit), no CR/LF. Two divu
;   steps give a full 32-bit quotient; digits are stacked then emitted.
_bootDebugDec32:
	movem.l	d0-d5/a0/a6,-(sp)
	move.l	(_AbsExecBase).w,a6
	move.l	sp,a0			;digit-stack marker
	tst.l	d0
	bne.s	_bdd_loop
	moveq.l	#'0',d0
	jsr	RawPutChar(a6)
	bra.s	_bdd_done
_bdd_loop:
	move.l	d0,d1
	swap	d1
	and.l	#$0000ffff,d1
	divu	#10,d1			;quot_hi / rem_hi
	move.w	d1,d2			;quot_hi
	swap	d1
	move.w	d1,d3			;rem_hi
	moveq.l	#0,d1
	move.w	d3,d1
	swap	d1
	move.w	d0,d1			;rem_hi<<16 | low word
	divu	#10,d1			;quot_lo / remainder
	move.w	d1,d4			;quot_lo
	swap	d1
	move.w	d1,d5			;remainder 0..9
	move.w	d2,d0
	swap	d0
	move.w	d4,d0			;new quotient
	add.b	#'0',d5
	move.b	d5,-(sp)
	tst.l	d0
	bne.s	_bdd_loop
_bdd_emit:
	cmp.l	sp,a0
	beq.s	_bdd_done
	moveq.l	#0,d0
	move.b	(sp)+,d0
	jsr	RawPutChar(a6)
	bra.s	_bdd_emit
_bdd_done:
	movem.l	(sp)+,d0-d5/a0/a6
	rts

;-- Print " (<dostype>, <MB> MB)" + CR/LF for the PartEntry in a3.
;   MB = pe_BlockCount >> 11 (512-byte sectors -> MiB).
_bootDebugPartTail:
	movem.l	d0/a0,-(sp)
	lea	s_pt_lparen(pc),a0
	bsr	_bootDebug
	move.l	pe_DosType(a3),d0
	bsr	_bootDebugDosType
	lea	s_pt_comma(pc),a0
	bsr	_bootDebug
	move.l	pe_BlockCount(a3),d0
	lsr.l	#8,d0
	lsr.l	#3,d0
	bsr	_bootDebugDec32
	lea	s_pt_mbnl(pc),a0
	bsr	_bootDebug
	movem.l	(sp)+,d0/a0
	rts

s_pt_lparen:	dc.b	" (",0
s_pt_comma:	dc.b	", ",0
s_pt_mbnl:	dc.b	" MB)",CR,LF,0
	even
	endc	;DEBUG
