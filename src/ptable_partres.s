;===========================================================
; ptable_partres.s - partition.resource + the runtime LVOs
;
; The resource (layout in ptable_pub.i: PTR_* / pe_*) is the single
; source of truth for discovered partitions. This file owns its
; create-or-open, the writer lock, entry alloc/free helpers, and the
; three runtime LVO bodies, which are thin wrappers:
;
;   ScanPartitions    = ctx + lock + _scanRun           (publish only)
;   MountPartitions   = ctx + lock + _actMount          (process context)
;   UnmountPartitions = ctx + lock + _actUnmount        (process context)
;
; The cold-stage LVO (BootScanPartitions) lives in ptable_boot.s and uses
; the same scan/act stages.
;===========================================================

PartResName:
	dc.b	"partition.resource",0
	even

;-- trace strings (DEBUG builds; PTMSG/PTNUM macros in ptable_boot.s)
	ifd	DEBUG
dbg_pt_scan:
	dc.b	"[PT] scanning for partitions",CR,LF,0
dbg_pt_open:
	dc.b	"[PT] cannot open device (no media?)",CR,LF,0
dbg_pt_recs:
	dc.b	"[PT] partitions found: ",0
dbg_pt_mbr:
	dc.b	"[PT] MBR partition table",CR,LF,0
dbg_pt_gpt:
	dc.b	"[PT] GPT partition table",CR,LF,0
dbg_pt_flat:
	dc.b	"[PT] whole-disk FAT (superfloppy)",CR,LF,0
dbg_pt_mnt:
	dc.b	"[PT] mounting partitions",CR,LF,0
dbg_pt_umnt:
	dc.b	"[PT] unmounting partitions",CR,LF,0
dbg_pt_umnt_busy:
	dc.b	"[PT] handler still alive after ACTION_DIE, kept absent",CR,LF,0
dbg_pt_mounted:
	dc.b	"[PT] mounted ",0
dbg_pt_reuse:
	dc.b	"[PT] reusing handler ",0
dbg_pt_unmounted:
	dc.b	"[PT] unmounted ",0
dbg_pt_mountedas:
	dc.b	"[PT] mounted as ",0
dbg_pt_absent:
	dc.b	"[PT] card removed, media absent",CR,LF,0
	even
	endc

;===========================================================
; _partGetResource: OpenResource / create+AddResource.
; In : a5 = ExecBase
; Out: d0 = resource ptr (0 on alloc failure)
;===========================================================
_partGetResource:
	move.l	a6,-(sp)
	move.l	a5,a6
	lea	PartResName(pc),a1
	jsr	OpenResource(a6)
	tst.l	d0
	bne.s	_pgr_end
	moveq.l	#PTR_Sizeof,d0
	move.l	#MEMF_PUBLIC+MEMF_CLEAR,d1
	jsr	AllocMem(a6)
	tst.l	d0
	beq.s	_pgr_end
	move.l	d0,a0
;-- Node + struct Library head (so resource viewers show version/id cleanly)
	move.b	#NT_RESOURCE,LN_Type(a0)
	lea	PartResName(pc),a1
	move.l	a1,LN_Name(a0)
	move.w	#LIB_VERSION,LIB_Version(a0)
	move.w	#LIB_REVISION,LIB_Revision(a0)
	lea	s_libidstring(pc),a1
	move.l	a1,LIB_IdString(a0)
	move.w	#PTR_Sizeof,LIB_PosSize(a0)
;-- runtime layout stamps: the only version signal OpenResource offers
	move.w	#PTR_LAYOUT_V,PTR_Layout(a0)
	move.w	#pe_Sizeof,PTR_EntrySize(a0)
;-- embedded empty List at PTR_PartList
	lea	PTR_PartList(a0),a1
	move.l	a1,(a1)
	addq.l	#4,(a1)
	clr.l	4(a1)
	move.l	a1,8(a1)
;-- embedded SignalSemaphore at PTR_Lock
	move.l	a0,-(sp)
	lea	PTR_Lock(a0),a0
	jsr	InitSemaphore(a6)
	move.l	(sp),a1
	jsr	AddResource(a6)
	move.l	(sp)+,d0
_pgr_end:
	move.l	(sp)+,a6
	rts

;===========================================================
; _partLockRes / _partUnlockRes: writer lock on the resource.
; Every LVO holds it for its whole run so concurrent callers (the
; cfd mount worker, a fat95 auto-detect handler, the cold stage)
; cannot interleave scan/publish/act. Lock order: PTR_Lock is the
; OUTER lock; DOS list locks are only ever taken inside it.
; Deadlock-free because the acts only STARTPROC explicit-geometry
; nodes, whose handler never calls back into a ptable LVO at startup.
;
; _partLockRes:   a5 = ExecBase -> d0 = resource (0 = fail, not locked)
; _partUnlockRes: a5 = ExecBase; preserves all registers
;===========================================================
_partLockRes:
	move.l	a6,-(sp)
	bsr	_partGetResource
	tst.l	d0
	beq.s	_plr_out
	move.l	d0,-(sp)
	move.l	d0,a0
	lea	PTR_Lock(a0),a0
	move.l	a5,a6
	jsr	ObtainSemaphore(a6)
	move.l	(sp)+,d0
_plr_out:
	move.l	(sp)+,a6
	rts

_partUnlockRes:
	movem.l	d0-d1/a0-a1/a6,-(sp)
	bsr	_partGetResource
	tst.l	d0
	beq.s	_pur_out
	move.l	d0,a0
	lea	PTR_Lock(a0),a0
	move.l	a5,a6
	jsr	ReleaseSemaphore(a6)
_pur_out:
	movem.l	(sp)+,d0-d1/a0-a1/a6
	rts

;-- _partTryLockRes: like _partLockRes but never blocks. d0 = resource
;   when the lock was obtained, 0 when it is missing or BUSY. For
;   best-effort callers (MarkAbsent) that may run on a handler the
;   current lock holder is waiting on - blocking there deadlocks.
_partTryLockRes:
	move.l	a6,-(sp)
	bsr	_partGetResource
	tst.l	d0
	beq.s	_ptl_out
	move.l	d0,-(sp)
	move.l	d0,a0
	lea	PTR_Lock(a0),a0
	move.l	a5,a6
	jsr	AttemptSemaphore(a6)
	move.l	(sp)+,d1		;resource ptr (pop BEFORE the test:
	tst.l	d0			; move.l to a data reg sets CC)
	beq.s	_ptl_busy
	move.l	d1,d0			;got it -> d0 = resource
	bra.s	_ptl_out
_ptl_busy:
	moveq.l	#0,d0			;busy -> caller skips
_ptl_out:
	move.l	(sp)+,a6
	rts

;===========================================================
; _psReadLBA: read one 512B block at an arbitrary 32-bit LBA.
; Doubles as the block-reader callback for _partScanGPT.
;
; In : d0 = LBA, a4 = &BootCtx
; Out: d0 = 0 on success (nonzero IO_Error otherwise),
;      a0 = &BC_BlockBuf
; Preserves d2-d7 (valid parts.s callback).
;===========================================================
_psReadLBA:
	movem.l	d1-d3/a1,-(sp)
	move.l	d0,d3			;d3 = LBA
	move.l	d3,d1
	lsl.l	#8,d1
	add.l	d1,d1			;d1 = LBA<<9 = low32 byte offset
	move.l	d3,d0
	lsr.l	#8,d0
	lsr.l	#8,d0
	lsr.l	#7,d0			;d0 = LBA>>23 = high32 byte offset
	move.l	#RDB_BLOCK_BYTES,d2
	move.l	BC_BlockBuf(a4),a1
	bsr	_bootReadBytes64
	move.l	BC_BlockBuf(a4),a0
	movem.l	(sp)+,d1-d3/a1
	rts

;===========================================================
; _psStrEq: NUL-terminated string compare (case-sensitive).
; In : a0, a1 ; Out: d0 = 1 if equal else 0
;===========================================================
_psStrEq:
	movem.l	a0-a1,-(sp)
_pse_l:
	move.b	(a0)+,d0
	cmp.b	(a1)+,d0
	bne.s	_pse_ne
	tst.b	d0
	bne.s	_pse_l
	moveq.l	#1,d0
	movem.l	(sp)+,a0-a1
	rts
_pse_ne:
	moveq.l	#0,d0
	movem.l	(sp)+,a0-a1
	rts

;===========================================================
; _psStrDup: copy a C-string into a fresh MEMF_PUBLIC alloc.
; In : a0 = src, a5 = ExecBase ; Out: d0 = ptr or 0
;===========================================================
_psStrDup:
	movem.l	d2/a2-a3/a6,-(sp)
	move.l	a0,a2			;a2 = src
	moveq.l	#0,d2
_psd_cl:
	tst.b	(a0)+
	beq.s	_psd_cd
	addq.l	#1,d2
	bra.s	_psd_cl
_psd_cd:
	move.l	d2,d0
	addq.l	#1,d0			;+NUL
	move.l	#MEMF_PUBLIC,d1
	move.l	a5,a6
	jsr	AllocMem(a6)
	tst.l	d0
	beq.s	_psd_out
	move.l	d0,a3
	move.l	a2,a0
	move.l	a3,a1
_psd_cp:
	move.b	(a0)+,(a1)+
	bne.s	_psd_cp
	move.l	a3,d0
_psd_out:
	movem.l	(sp)+,d2/a2-a3/a6
	rts

;===========================================================
; _psFreeEntry: free pe_Device copy + the PartEntry node.
; (The DN blob, if any, is freed separately by the caller.)
; In : a0 = PartEntry, a5 = ExecBase
;===========================================================
_psFreeEntry:
	movem.l	d2/a2/a6,-(sp)
	move.l	a0,a2
	move.l	a5,a6
	move.l	pe_Device(a2),d0
	beq.s	_pfe_node
	move.l	d0,a0
	moveq.l	#0,d2
_pfe_l:
	tst.b	(a0)+
	beq.s	_pfe_d
	addq.l	#1,d2
	bra.s	_pfe_l
_pfe_d:
	addq.l	#1,d2
	move.l	pe_Device(a2),a1
	move.l	d2,d0
	jsr	FreeMem(a6)
_pfe_node:
	move.l	a2,a1
	moveq.l	#0,d0
	move.w	pe_Length(a2),d0	;free the size it was allocated with
	bne.s	_pfe_free		;(a future publisher may grow entries)
	move.l	#pe_Sizeof,d0		;unstamped -> our own build size
_pfe_free:
	jsr	FreeMem(a6)
	movem.l	(sp)+,d2/a2/a6
	rts

;===========================================================
; _partCtxAlloc: allocate + prime a BootCtx for a runtime LVO.
; In : d6 = devName, d5 = unit, a5 = ExecBase
; Out: d0 = &BootCtx or 0
;===========================================================
_partCtxAlloc:
	move.l	a6,-(sp)
	move.l	#BC_Sizeof+BC_BUF_BYTES,d0
	move.l	#MEMF_PUBLIC+MEMF_CLEAR,d1
	move.l	a5,a6
	jsr	AllocMem(a6)
	tst.l	d0
	beq.s	_pca_out
	move.l	d0,a0
	move.l	a5,BC_ExecBase(a0)
	move.l	d6,BC_DevName(a0)
	move.l	d5,BC_Unit(a0)
	lea	BC_Sizeof(a0),a1
	move.l	a1,BC_BlockBuf(a0)
	move.b	#-1,BC_SigOK(a0)
_pca_out:
	move.l	(sp)+,a6
	rts

;-- _partCtxFree: a4 = &BootCtx, a5 = ExecBase (preserves d0)
_partCtxFree:
	movem.l	d0-d1/a0-a1/a6,-(sp)
	move.l	a4,a1
	move.l	#BC_Sizeof+BC_BUF_BYTES,d0
	move.l	a5,a6
	jsr	FreeMem(a6)
	movem.l	(sp)+,d0-d1/a0-a1/a6
	rts

;===========================================================
; ScanPartitions(devName:a1, unit:d0, LibBase:a6) -> d0 = published
;
; Publish only: open the unit, run the unified scanner, close.
; Exec-only; callable from any task context.
;===========================================================
ScanPartitions:
	movem.l	d2-d7/a2-a6,-(sp)
	move.l	a1,d6			;d6 = devName
	move.l	d0,d5			;d5 = unit
	move.l	RDBL_ExecBase(a6),a5	;a5 = ExecBase
	PTMSG	dbg_pt_scan
	bsr	_partCtxAlloc
	tst.l	d0
	beq.w	_sp_ret0
	move.l	d0,a4

	bsr	_partLockRes
	tst.l	d0
	beq.s	_sp_unlocked
	bsr	_bootOpenUnit
	tst.l	d0
	beq.s	_sp_openfail
	bsr	_scanRun
	move.l	d0,d7
	bra.s	_sp_done2
_sp_openfail:
	PTMSG	dbg_pt_open		;"cannot open device (no media?)"
	moveq.l	#0,d7
_sp_done2:
	bsr	_partUnlockRes
	bra.s	_sp_close
_sp_unlocked:
	moveq.l	#0,d7
_sp_close:
	bsr	_bootCloseUnit
	bsr	_partCtxFree
	move.l	d7,d0
	movem.l	(sp)+,d2-d7/a2-a6
	rts
_sp_ret0:
	moveq.l	#0,d0
	movem.l	(sp)+,d2-d7/a2-a6
	rts

;===========================================================
; MountPartitions(devName:a1, unit:d0, cfg:a0, LibBase:a6) -> d0 = mounted
;
; Runtime act; CALL FROM A PROCESS (ADNF_STARTPROC handler start).
; cfg = MountCfg (0 = defaults); _actBuildBlob resolves each entry's Flags +
; Control by dostype and stamps fssm_Flags + de_Control on the node.
;===========================================================
MountPartitions:
	movem.l	d2-d7/a2-a6,-(sp)
	move.l	a0,d4			;MountCfg ptr (a0 not saved by movem)
	move.l	a1,d6
	move.l	d0,d5
	move.l	RDBL_ExecBase(a6),a5
	PTMSG	dbg_pt_mnt
	moveq.l	#0,d7
	bsr	_partCtxAlloc
	tst.l	d0
	beq.w	_mp_ret
	move.l	d0,a4
	move.l	d4,BC_MountCfg(a4)	;-> _actBuildBlob resolve

;-- expansion.library for AddDosNode
	moveq.l	#0,d0
	lea	ExpansionName(pc),a1
	move.l	a5,a6
	jsr	OpenLibrary(a6)
	move.l	d0,BC_ExpBase(a4)
	beq.s	_mp_free

;-- device-name BSTR for the FSSMs
	move.l	BC_DevName(a4),a0
	move.l	a5,a6
	bsr	_bootMakeExecBSTR
	move.l	d0,BC_DevNameBSTR(a4)
	beq.s	_mp_closeexp

	bsr	_partLockRes
	tst.l	d0
	beq.s	_mp_closeexp
	bsr	_actMount
	move.l	d0,d7
	bsr	_partUnlockRes

_mp_closeexp:
	move.l	BC_ExpBase(a4),d0
	beq.s	_mp_free
	move.l	a5,a6
	move.l	d0,a1
	jsr	CloseLibrary(a6)
_mp_free:
	bsr	_partCtxFree
_mp_ret:
	move.l	d7,d0
	movem.l	(sp)+,d2-d7/a2-a6
	rts

;===========================================================
; UnmountPartitions(devName:a1, unit:d0, prefixList:a0, LibBase:a6) -> d0
;
; Runtime teardown; CALL FROM A PROCESS (packet I/O, DOS list lock).
; prefixList = 0: tear down every matched entry. prefixList != 0
; (0-terminated dostype-prefix longwords): tear down matched dostypes,
; mark the rest absent (keep handler).
;===========================================================
UnmountPartitions:
	movem.l	d2-d7/a2-a6,-(sp)
	move.l	a1,d6
	move.l	d0,d5
	move.l	a0,d4			;prefixList (0 = all)
	move.l	RDBL_ExecBase(a6),a5
	PTMSG	dbg_pt_umnt
	moveq.l	#0,d7
	bsr	_partCtxAlloc
	tst.l	d0
	beq.s	_up_ret
	move.l	d0,a4
	move.l	d4,BC_UnmountPrefixes(a4)

;-- dos.library for RemDosEntry (0 is tolerated: act skips that step)
	moveq.l	#0,d0
	lea	DosName(pc),a1
	move.l	a5,a6
	jsr	OpenLibrary(a6)
	move.l	d0,BC_DosBase(a4)

;-- expansion.library for the eb_MountList BootNode unlink at teardown
;   (0 is tolerated: _actTeardownEntry then keeps the blob to avoid a
;   dangling bn_DeviceNode)
	moveq.l	#0,d0
	lea	ExpansionName(pc),a1
	move.l	a5,a6
	jsr	OpenLibrary(a6)
	move.l	d0,BC_ExpBase(a4)

	bsr	_partLockRes
	tst.l	d0
	beq.s	_up_closedos
	bsr	_actUnmount
	move.l	d0,d7
	bsr	_partUnlockRes

_up_closedos:
	move.l	BC_ExpBase(a4),d0
	beq.s	_up_closedos2
	move.l	a5,a6
	move.l	d0,a1
	jsr	CloseLibrary(a6)
_up_closedos2:
	move.l	BC_DosBase(a4),d0
	beq.s	_up_free
	move.l	a5,a6
	move.l	d0,a1
	jsr	CloseLibrary(a6)
_up_free:
	bsr	_partCtxFree
_up_ret:
	move.l	d7,d0
	movem.l	(sp)+,d2-d7/a2-a6
	rts

;===========================================================
; RegisterPartition(deviceName:a1, unit:d0, startLBA:d1, blockCount:d2,
;               nameBSTR:a0, devNode:a2, LibBase:a6) -> d0 = 1/0
;
; Overlay a real mount onto an already-published entry (matched by
; device+unit+start+count): set its name to the handler's real DOS name,
; mark it MOUNTED, and record the DeviceNode. Find-only; Exec context.
;===========================================================
RegisterPartition:
	movem.l	d2-d7/a2-a6,-(sp)
	move.l	d4,-(sp)		;[4(sp)] = control APTR input (BSTR or 0)
	move.l	d3,-(sp)		;[0(sp)] = flags input
	move.l	d0,d3			;d3 = unit
	move.l	d1,d4			;d4 = startLBA
	move.l	d2,d5			;d5 = blockCount
	move.l	a0,a3			;a3 = name BSTR
	move.l	a1,a4			;a4 = device name (C string)
	move.l	a2,d6			;d6 = devNode
	move.l	RDBL_ExecBase(a6),a5
	moveq.l	#0,d2			;d2 = result (0 = not found)

	bsr	_partLockRes		;d0 = resource ptr (0 = fail)
	tst.l	d0
	beq.w	_rm_unlocked
	move.l	d0,a0
	lea	PTR_PartList(a0),a0
	move.l	(a0),d7			;d7 = first node
_rm_walk:
	move.l	d7,a0			;a0 = entry
	move.l	(a0),d1			;d1 = succ
	beq.w	_rm_unlock		;tail -> not found
	cmp.l	pe_Unit(a0),d3
	bne.w	_rm_next
	cmp.l	pe_StartLBA(a0),d4	;match on start only (FS size may
	bne.w	_rm_next		; differ from the partition size)
	move.l	pe_Device(a0),a0	;a0 = entry's device C string
	move.l	a4,a1			;a1 = wanted device name
	bsr	_psStrEq		;d0=1/0; preserves d1-d7,a2-a6
	tst.l	d0
	beq.w	_rm_next

;-- match: copy the real DOS name into pe_MountName (clamp 31), leaving the
;   generated pe_NameB intact; mark mounted, record devnode
	move.l	d7,a0
	lea	pe_MountName(a0),a1
	moveq.l	#0,d0
	move.b	(a3),d0			;length byte
	cmp.b	#31,d0
	bls.s	_rm_lenok
	moveq.l	#31,d0
_rm_lenok:
	move.b	d0,(a1)+		;clamped length
	lea	1(a3),a2		;a2 = source chars
	tst.b	d0
	beq.s	_rm_nameset
_rm_ncp:
	move.b	(a2)+,(a1)+
	subq.b	#1,d0
	bne.s	_rm_ncp
_rm_nameset:
	move.l	d7,a0
	bset	#PEB_MOUNTED,pe_Flags(a0)
	move.l	d6,pe_DevNode(a0)
	moveq.l	#1,d2			;updated
	ifd	DEBUG
	lea	dbg_pt_mountedas(pc),a0
	bsr	_bootDebug
	move.l	d7,a0
	lea	pe_MountName(a0),a0
	bsr	_bootDebugBStr
	endc
;-- record the Flags + Control the handler actually opened with (visibility)
	move.l	d7,a0
	move.l	(sp),d0			;flags input
	move.l	d0,pe_MountFlags(a0)
	lea	pe_Control(a0),a1
	move.l	4(sp),d0		;control APTR (0 = none)
	beq.s	_rm_noctl
	move.l	d0,a2			;src BSTR
	moveq.l	#0,d0
	move.b	(a2)+,d0		;length
	cmp.b	#31,d0
	bls.s	_rm_clen
	moveq.l	#31,d0
_rm_clen:
	move.b	d0,(a1)+		;clamped length
	tst.b	d0
	beq.s	_rm_unlock
_rm_ccp:
	move.b	(a2)+,(a1)+
	subq.b	#1,d0
	bne.s	_rm_ccp
	bra.s	_rm_unlock
_rm_noctl:
	clr.b	(a1)			;empty control
	bra.s	_rm_unlock
_rm_next:
	move.l	d1,d7			;cursor = succ
	bra.w	_rm_walk
_rm_unlock:
	bsr	_partUnlockRes
_rm_unlocked:
	move.l	d2,d0
	addq.l	#8,sp			;drop saved flags + control inputs
	movem.l	(sp)+,d2-d7/a2-a6
	rts

;===========================================================
; MarkAbsent(devName: a1, unit: d0) -> d0 = count cleared
; Media gone (card removed): clear PEB_PRESENT (and PEB_INVALID, so a mounted
; slot reads as plain absent, not invalid) on every entry for device+unit,
; leaving PEB_MOUNTED / pe_DevNode / the DOS node / the handler intact. The handler ejects its volume via the device's own disk-change
; notify; a later ScanPartitions re-sets PEB_PRESENT on reinsert.
; a6 = library base.
;===========================================================
MarkAbsent:
	movem.l	d2-d7/a2-a6,-(sp)
	move.l	d0,d3			;d3 = unit
	move.l	a1,a4			;a4 = device name (C string)
	move.l	RDBL_ExecBase(a6),a5
	moveq.l	#0,d2			;d2 = count cleared

;-- best-effort: NEVER block on PTR_Lock. MarkAbsent runs on the dying
;   handler's own context (fat95 CloseDisk) while UnmountPartitions may
;   hold the lock polling for that very handler's death - blocking here
;   stalls the DIE past the poll. A busy lock means a ptable op that
;   supersedes this flag clear anyway (teardown frees the entry, a scan
;   re-derives PRESENT), so just skip.
	bsr	_partTryLockRes		;d0 = resource ptr (0 = fail/busy)
	tst.l	d0
	beq.s	_ma_unlocked
	move.l	d0,a0
	lea	PTR_PartList(a0),a0
	move.l	(a0),d7			;d7 = first node
_ma_walk:
	move.l	d7,a0			;a0 = entry
	move.l	(a0),d1			;d1 = succ
	beq.s	_ma_unlock		;tail
	cmp.l	pe_Unit(a0),d3
	bne.s	_ma_next
	move.l	pe_Device(a0),a0	;a0 = entry's device C string
	move.l	a4,a1			;a1 = wanted device name
	bsr	_psStrEq		;d0=1/0; preserves d1-d7,a2-a6
	tst.l	d0
	beq.s	_ma_next
	move.l	d7,a0
	bclr	#PEB_PRESENT,pe_Flags(a0)
	bclr	#PEB_INVALID,pe_Flags(a0)	;no media -> plain absent, not invalid
	addq.l	#1,d2
_ma_next:
	move.l	d1,d7			;cursor = succ
	bra.s	_ma_walk
_ma_unlock:
	ifd	DEBUG
	lea	dbg_pt_absent(pc),a0
	bsr	_bootDebug
	endc
	bsr	_partUnlockRes
_ma_unlocked:
	move.l	d2,d0
	movem.l	(sp)+,d2-d7/a2-a6
	rts
