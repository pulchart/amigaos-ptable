;===========================================================
; ptable_scan.s - detection + publish stage
;
; One scanner for every supported scheme. _scanRun detects what is
; on the medium (RDB, superfloppy FAT boot block, MBR, GPT) and
; publishes one PartEntry per partition into partition.resource with
; everything the act stages need (DosEnvec, name, boot priority,
; classification) materialised at publish time. No mounting here.
;
; Callers hold ptr_Lock and have the unit open:
;   a4 = &BootCtx, a5 = ExecBase.
;===========================================================

;-- superfloppy BPB total-sector fields (little-endian, block 0)
BPB_TOTAL16	= 19
BPB_TOTAL32	= 32

;===========================================================
; _scanRun: detect + publish for BC_DevName/BC_Unit.
; In : a4 = &BootCtx (unit open), a5 = ExecBase; PTR_Lock held
; Out: d0 = entries published this call
;===========================================================
_scanRun:
	movem.l	d2-d7/a2-a3/a6,-(sp)
	moveq.l	#0,d7			;d7 = published count

;-- whole-unit reconcile: clear PRESENT for this device+unit; the publishers
;   below re-set it only on the slots the current card actually has, and
;   _scanPurge at _srn_out then drops the now-absent ones (keeping mounted)
	bsr	_scanClearPresent

;-- valid RDSK in blocks 0..15?
	moveq.l	#0,d6
_srn_rdsk:
	move.l	d6,d0
	bsr	_bootReadBlock
	tst.l	d0
	bne.s	_srn_rdsk_next
	move.l	BC_BlockBuf(a4),a0
	cmpi.l	#RDSK_ID,(a0)
	bne.s	_srn_rdsk_next
	move.l	rdb_SummedLongs(a0),d1
	cmp.l	#128,d1
	bhi.s	_srn_rdsk_next
	bsr	_bootChecksum
	beq.w	_srn_rdb
_srn_rdsk_next:
	addq.l	#1,d6
	cmp.l	#RDB_LOCATION_LIMIT,d6
	blo.s	_srn_rdsk

;-- no RDB: classify block 0
	moveq.l	#0,d0
	bsr	_bootReadBlock
	tst.l	d0
	bne.w	_srn_out
	move.l	BC_BlockBuf(a4),a0
	bsr	_partIsBootBlock	;FAT BPB straight at LBA 0?
	tst.l	d0
	bne.w	_srn_flat
	move.l	BC_BlockBuf(a4),a0
	cmpi.w	#$55AA,510(a0)
	bne.w	_srn_none		;nothing recognised
	cmpi.b	#$EE,446+4(a0)
	beq.w	_srn_gpt
	bra.w	_srn_mbr

_srn_none:
	PTMSG	dbg_boot_no_rdb		;"[PT] nothing recognised"
	bra.w	_srn_out

;- - RDB: FSHD handler load, then publish each PART block - -
;   (a slot already present is refreshed in place via _scanFindSlot
;    inside the publishers, so a rescan of the boot card or a swapped
;    card updates entries rather than duplicating them)
_srn_rdb:
	ifd	DEBUG
	lea	dbg_boot_rdsk_found(pc),a0
	bsr	_bootDebug
	endc
	move.l	BC_BlockBuf(a4),a0
	move.l	rdb_PartitionList(a0),d5	;d5 = partition list head
	move.l	rdb_FileSysHeaderList(a0),d4	;d4 = fshd list head

;-- Phase 1: filesystems carried in the RDB (hop-capped walk; see the
;   cycle-breaker rationale at the FSHD walk in BootScanPartitions)
	move.l	d4,d3
	moveq.l	#16,d2
_srn_fs_loop:
	move.l	d3,d0
	addq.l	#1,d0			;-1 -> 0 (end sentinel)
	beq.s	_srn_fs_done
	subq.l	#1,d2
	bmi.s	_srn_fs_done
	move.l	d3,d6
	move.l	d3,d0
	bsr	_bootReadBlock
	tst.l	d0
	bne.s	_srn_fs_done
	move.l	BC_BlockBuf(a4),a0
	cmpi.l	#FSHD_ID,(a0)
	bne.s	_srn_fs_done
	move.l	fhb_Next(a0),d3
	bsr	_bootAddOneFileSys
	cmp.l	d3,d6			;self-loop guard
	beq.s	_srn_fs_done
	bra.s	_srn_fs_loop
_srn_fs_done:

;-- Phase 2: publish partitions (hop-capped walk)
	move.l	d5,d3
	moveq.l	#127,d2
	moveq.l	#0,d5			;d5 = partition index
_srn_pt_loop:
	move.l	d3,d0
	addq.l	#1,d0
	beq.w	_srn_out
	subq.l	#1,d2
	bmi.w	_srn_out
	move.l	d3,d6
	move.l	d3,d0
	bsr	_bootReadBlock
	tst.l	d0
	bne.w	_srn_out
	move.l	BC_BlockBuf(a4),a0
	cmpi.l	#PART_ID,(a0)
	bne.w	_srn_out
	move.l	pb_Next(a0),d3
	bsr	_scanPubRDB		;d5 = index; buffer = PART block
	add.l	d0,d7
	addq.l	#1,d5
	cmp.l	d3,d6
	beq.w	_srn_out
	bra.s	_srn_pt_loop

;- - superfloppy: one whole-disk FAT entry - - - - - - - - -
_srn_flat:
	PTMSG	dbg_pt_flat
;-- a0 = block 0 with a validated FAT BPB; total sectors is the
;   little-endian word at 19, or the long at 32 when the word is 0
	moveq.l	#0,d1
	move.b	BPB_TOTAL16+1(a0),d1
	lsl.w	#8,d1
	move.b	BPB_TOTAL16(a0),d1
	tst.w	d1
	bne.s	_srn_fl_have
	move.l	BPB_TOTAL32(a0),d1
	REVL	d1
_srn_fl_have:
	tst.l	d1
	beq.w	_srn_out
	bsr	_scanPubFlat		;d1 = total sectors
	add.l	d0,d7
	bra.w	_srn_out

;- - MBR / GPT: walker -> PartRec[] -> publish - - - - - - -
_srn_mbr:
	PTMSG	dbg_pt_mbr
	lea	-128(sp),sp		;PART_MAX_REC * PR_Sizeof
	move.l	sp,a2			;a2 = PartRec buffer
	move.l	BC_BlockBuf(a4),a0
	bsr	_partScanMBR
	moveq.l	#PES_MBR,d6
	bra.s	_srn_pubrecs
_srn_gpt:
	PTMSG	dbg_pt_gpt
	lea	-128(sp),sp
	move.l	sp,a2
	lea	_psReadLBA(pc),a3
	bsr	_partScanGPT
	moveq.l	#PES_GPT,d6
_srn_pubrecs:
	move.l	d0,d5			;d5 = record count
	moveq.l	#0,d4			;d4 = record index
_srn_pr_loop:
	cmp.l	d5,d4
	bhs.s	_srn_pr_done
	move.l	d4,d0
	mulu.w	#PR_Sizeof,d0
	lea	0(a2,d0.l),a3		;a3 = &PartRec[d4]
;-- boot-block sanity gate before publishing
	move.l	PR_StartLBA(a3),d0
	bsr	_psReadLBA
	tst.l	d0
	bne.s	_srn_pr_next
	cmpi.w	#$55AA,510(a0)
	bne.s	_srn_pr_next
	bsr	_partIsBootBlock
	tst.l	d0
	beq.s	_srn_pr_next
	bsr	_scanPubRec		;a3 = &PartRec, d6 = source
	add.l	d0,d7
_srn_pr_next:
	addq.l	#1,d4
	bra.s	_srn_pr_loop
_srn_pr_done:
	lea	128(sp),sp

_srn_out:
;-- drop slots the current card no longer has (PRESENT still clear after the
;   reconcile): mounted ones are kept (shown absent ---M), unmounted
;   published-only ones are freed. Preserves d7 (the published count).
	bsr	_scanPurge
	move.l	d7,d0
	PTDEC	dbg_pt_recs
	movem.l	(sp)+,d2-d7/a2-a3/a6
	rts

;===========================================================
; _scanPubRDB: publish one RDB partition.
; In : BC_BlockBuf -> PART block, d5 = partition index,
;      a4 = &BootCtx, a5 = ExecBase
; Out: d0 = 1 published / 0 skipped
; Preserves d2-d7/a2-a3.
;===========================================================
_scanPubRDB:
	movem.l	d2-d6/a2-a3,-(sp)
	move.l	BC_BlockBuf(a4),a2	;a2 = PartitionBlock

;-- DosEnvec TableSize must include DOSTYPE and stay in bounds
	move.l	pb_Environment(a2),d2	;d2 = TableSize
	cmp.l	#DE_DOSTYPE,d2
	blo.w	_spr_skip
	cmp.l	#20,d2
	bhi.w	_spr_skip

;-- geometry summary first (it is also the duplicate key):
;   cylblocks = Surfaces * BlocksPerTrack;
;   start = LowCyl * cylblocks; count = (HighCyl-LowCyl+1) * cylblocks
	move.l	pb_Environment+DE_Surfaces*4(a2),d0
	move.l	pb_Environment+DE_BlocksPerTrk*4(a2),d1
	UMUL32
	move.l	d0,d4			;d4 = cylblocks
	move.l	pb_Environment+DE_LowCyl*4(a2),d0
	move.l	d4,d1
	UMUL32
	move.l	d0,d6			;d6 = start
	move.l	pb_Environment+DE_HighCyl*4(a2),d0
	sub.l	pb_Environment+DE_LowCyl*4(a2),d0
	addq.l	#1,d0
	move.l	d4,d1
	UMUL32
	move.l	d0,d4			;d4 = block count

;-- same slot already present (rescan / card swap)?  refresh it in place
	move.l	d6,d0
	bsr	_scanFindSlot
	tst.l	d0
	bne.w	_spr_upd

	bsr	_scanAllocEntry
	tst.l	d0
	beq.w	_spr_skip
	move.l	d0,a3			;a3 = new PartEntry
	bsr	_scanFillRDB
	move.l	a3,a0
	bsr	_scanLinkEntry
	moveq.l	#1,d0			;newly published
	movem.l	(sp)+,d2-d6/a2-a3
	rts
_spr_upd:
	move.l	d0,a3			;existing entry: refresh in place
	bsr	_scanFillRDB
	moveq.l	#0,d0			;re-confirm, not newly published
	movem.l	(sp)+,d2-d6/a2-a3
	rts
_spr_skip:
	moveq.l	#0,d0
	movem.l	(sp)+,d2-d6/a2-a3
	rts

;===========================================================
; _scanFillRDB: write one RDB partition block (pb at a2) into an entry.
; In : a2 = pb, a3 = entry, d2 = envec TableSize, d4 = blockCount, d5 = index,
;      d6 = startLBA, a4, a5. Sets PEB_PRESENT/BOOTABLE/NOMOUNT per pb_Flags,
;      PRESERVES PEB_MOUNTED; refreshes geometry, bootpri, dostype, envec, and
;      the on-disk drive name. Leaves the mount overlay intact.
;===========================================================
_scanFillRDB:
	move.l	d6,pe_StartLBA(a3)
	move.l	d4,pe_BlockCount(a3)
	move.l	d5,pe_PartIndex(a3)
	move.b	#PES_RDB,pe_Source(a3)
	moveq.l	#1<<PEB_PRESENT,d1
	move.l	pb_Flags(a2),d0
	btst	#PBFFB_BOOTABLE,d0
	beq.s	_frd_nb
	bset	#PEB_BOOTABLE,d1
_frd_nb:
	btst	#PBFFB_NOMOUNT,d0
	beq.s	_frd_nm
	bset	#PEB_NOMOUNT,d1
_frd_nm:
	move.b	pe_Flags(a3),d0		;preserve PEB_MOUNTED
	and.b	#1<<PEB_MOUNTED,d0
	or.b	d1,d0
	move.b	d0,pe_Flags(a3)
	move.l	pb_Environment+DE_BOOTPRI*4(a2),pe_BootPri(a3)
	move.l	pb_Environment+DE_DOSTYPE*4(a2),pe_DosType(a3)
	lea	pb_Environment(a2),a0
	lea	pe_Envec(a3),a1
	move.l	d2,d3
	addq.l	#1,d3
	cmp.l	#21,d3			;pe_Envec holds 21 longs; clamp a
	bls.s	_frd_ecp		;bogus on-disk DE_TABLESIZE so the
	moveq.l	#21,d3			;copy cannot overrun into pe_ReadMode
_frd_ecp:
	move.l	(a0)+,(a1)+
	subq.l	#1,d3
	bne.s	_frd_ecp
	lea	pb_DriveName(a2),a0
	lea	pe_NameB(a3),a1
	moveq.l	#0,d3
	move.b	(a0)+,d3
	cmp.b	#31,d3
	bls.s	_frd_nok
	moveq.l	#31,d3
_frd_nok:
	move.b	d3,(a1)+
	bra.s	_frd_ntst
_frd_ncp:
	move.b	(a0)+,(a1)+
_frd_ntst:
	dbra	d3,_frd_ncp
	rts

;===========================================================
; _scanPubRec: publish one MBR/GPT PartRec.
; In : a3 = &PartRec, d6 = PES_MBR/PES_GPT, a4, a5
; Out: d0 = 1 published / 0 failed
; Preserves d2-d7/a2-a3.
;===========================================================
_scanPubRec:
	movem.l	d2-d3/a2-a3,-(sp)
	move.l	a3,a2			;a2 = PartRec

;-- same slot already present (rescan / card swap)?  refresh it in place
	moveq.l	#0,d0
	move.b	PR_PartIndex(a2),d0	;identity = partition index (CFa<index>)
	bsr	_scanFindByIndex
	tst.l	d0
	bne.s	_spc_upd

	bsr	_scanAllocEntry
	tst.l	d0
	beq.s	_spc_fail
	move.l	d0,a3			;a3 = new PartEntry
	bsr	_scanFillRec
	move.l	a3,a0
	bsr	_scanLinkEntry
	moveq.l	#1,d0			;newly published
	movem.l	(sp)+,d2-d3/a2-a3
	rts
_spc_upd:
	move.l	d0,a3			;a3 = existing entry: refresh in place
	bsr	_scanFillRec
	moveq.l	#0,d0			;re-confirm, not newly published
	movem.l	(sp)+,d2-d3/a2-a3
	rts
_spc_fail:
	moveq.l	#0,d0
	movem.l	(sp)+,d2-d3/a2-a3
	rts

;===========================================================
; _scanFillRec: write MBR/GPT PartRec geometry into an entry.
; In : a2 = &PartRec, a3 = entry, d6 = PES_MBR/PES_GPT, a4, a5
; Sets PEB_PRESENT and PEB_BOOTABLE per the rec, PRESERVES PEB_MOUNTED, and
; refreshes geometry, envec, and the synthesized name. Leaves the mount
; overlay (pe_MountName/pe_DevNode/pe_BlobPtr/pe_MountFlags/pe_Control) intact.
;===========================================================
_scanFillRec:
	moveq.l	#0,d0
	move.b	PR_PartIndex(a2),d0
	move.l	d0,pe_PartIndex(a3)
	move.b	d6,pe_Source(a3)
	moveq.l	#1<<PEB_PRESENT,d1
	move.b	PR_Flags(a2),d2
	btst	#PRFB_BOOTABLE,d2
	beq.s	_sfr_nb
	bset	#PEB_BOOTABLE,d1	;informational for FAT (never booted)
_sfr_nb:
	move.b	pe_Flags(a3),d2		;preserve PEB_MOUNTED across the refresh
	and.b	#1<<PEB_MOUNTED,d2
	or.b	d1,d2
	move.b	d2,pe_Flags(a3)
	move.l	PR_DosType(a2),pe_DosType(a3)
	move.l	PR_StartLBA(a2),pe_StartLBA(a3)
	move.l	PR_BlockCount(a2),pe_BlockCount(a3)
	lea	pe_Envec(a3),a0
	move.l	PR_StartLBA(a2),d0
	move.l	PR_BlockCount(a2),d1
	move.l	PR_DosType(a2),d2
	bsr	_scanFillEnvec
	move.l	pe_PartIndex(a3),d0
	bsr	_scanSynthName		;a3 = entry, d0 = index
	rts

;===========================================================
; _scanPubFlat: publish the superfloppy whole-disk entry.
; In : d1 = total sectors, a4, a5
; Out: d0 = 1 published / 0 failed
;===========================================================
_scanPubFlat:
	movem.l	d2-d3/a2-a3,-(sp)
	move.l	d1,d3			;d3 = total sectors

;-- same slot (whole-disk = index 0) already present?  refresh it in place
	moveq.l	#0,d0			;slot index 0
	bsr	_scanFindByIndex
	tst.l	d0
	bne.s	_spf_upd

	bsr	_scanAllocEntry
	tst.l	d0
	beq.s	_spf_fail
	move.l	d0,a3
	bsr	_scanFillFlat
	move.l	a3,a0
	bsr	_scanLinkEntry
	moveq.l	#1,d0			;newly published
	movem.l	(sp)+,d2-d3/a2-a3
	rts
_spf_upd:
	move.l	d0,a3			;existing entry: refresh in place
	bsr	_scanFillFlat
	moveq.l	#0,d0			;re-confirm, not newly published
	movem.l	(sp)+,d2-d3/a2-a3
	rts
_spf_fail:
	moveq.l	#0,d0
	movem.l	(sp)+,d2-d3/a2-a3
	rts

;===========================================================
; _scanFillFlat: write the superfloppy whole-disk geometry into an entry.
; In : a3 = entry, d3 = total sectors, a4, a5. Sets PEB_PRESENT, preserves
; PEB_MOUNTED; leaves the mount overlay intact.
;===========================================================
_scanFillFlat:
	clr.l	pe_PartIndex(a3)
	move.b	#PES_FLAT,pe_Source(a3)
	bset	#PEB_PRESENT,pe_Flags(a3)	;preserve other flags (MOUNTED)
	move.l	#DOSTYPE_FAT,pe_DosType(a3)
	clr.l	pe_StartLBA(a3)
	move.l	d3,pe_BlockCount(a3)
	lea	pe_Envec(a3),a0
	moveq.l	#0,d0			;start
	move.l	d3,d1			;count
	move.l	#DOSTYPE_FAT,d2
	bsr	_scanFillEnvec
	moveq.l	#0,d0
	bsr	_scanSynthName
	rts

;===========================================================
; _scanAllocEntry: allocate a PartEntry with the common identity
; fields set (device-name copy, unit, LN_Name -> embedded name).
; In : a4 = &BootCtx, a5 = ExecBase
; Out: d0 = entry or 0
; Preserves d2-d7/a2-a3.
;===========================================================
_scanAllocEntry:
	movem.l	a2/a6,-(sp)
	move.l	#pe_Sizeof,d0
	move.l	#MEMF_PUBLIC+MEMF_CLEAR,d1
	move.l	a5,a6
	jsr	AllocMem(a6)
	tst.l	d0
	beq.s	_sae_out
	move.l	d0,a2
	move.l	BC_DevName(a4),a0
	bsr	_psStrDup
	tst.l	d0
	bne.s	_sae_ok
	move.l	a2,a1			;name dup failed: free entry
	move.l	#pe_Sizeof,d0
	move.l	a5,a6
	jsr	FreeMem(a6)
	moveq.l	#0,d0
	bra.s	_sae_out
_sae_ok:
	move.l	d0,pe_Device(a2)
	move.b	#NT_UNKNOWN,LN_Type(a2)
	lea	pe_NameB(a2),a0
	move.l	a0,LN_Name(a2)
	move.l	BC_Unit(a4),pe_Unit(a2)
	move.b	BC_ReadMode(a4),pe_ReadMode(a2)	;device read command used
	move.w	#pe_Sizeof,pe_Length(a2)	;layout stamp for consumers
	move.l	a2,d0
_sae_out:
	movem.l	(sp)+,a2/a6
	rts

;===========================================================
; _scanLinkEntry: AddTail under Forbid (readers walk under Forbid).
; In : a0 = entry, a5 = ExecBase
;===========================================================
_scanLinkEntry:
	movem.l	d0-d1/a0-a1/a6,-(sp)
	move.l	a0,-(sp)
	bsr	_partGetResource
	move.l	(sp)+,a1
	tst.l	d0
	beq.s	_sle_out
	move.l	d0,a0
	lea	PTR_PartList(a0),a0
	move.l	a5,a6
	jsr	Forbid(a6)
	jsr	AddTail(a6)
	jsr	Permit(a6)
_sle_out:
	movem.l	(sp)+,d0-d1/a0-a1/a6
	rts

;===========================================================
; _scanSynthName: write the synthesized partition name BSTR into
; pe_NameB. Used only for table-less media (MBR/GPT/superfloppy); RDB
; keeps its on-disk pb_DriveName.
;
; Name = PREFIX + unit + partition
;   PREFIX  abbreviation table value, else the device base name (trailing
;           ".device" stripped, kept A-Z/0-9 uppercased), truncated to fit
;   unit    lowercase letter 'a' + unit   (a..p for units 0..15)
;   part    decimal partition index, 0-based
; e.g. compactflash.device unit 0 -> CFa0 CFa1 CFa2   (table -> CF)
;      scsi.device         unit 0 -> SCSIa0 SCSIa1
;
; In : a3 = entry, d0 = partition index (0-based), a4 = &BootCtx
;===========================================================
_scanSynthName:
	movem.l	d0-d6/a0-a2,-(sp)
	move.l	d0,d4			;d4 = partition index (0-based)
	lea	pe_NameB(a3),a1
	addq.l	#1,a1			;a1 = char cursor (past length byte)

;-- partition digit count (1 or 2; indexes are well under 100)
	moveq.l	#1,d5
	cmp.l	#10,d4
	blo.s	_ssn_budget
	addq.l	#1,d5
_ssn_budget:
;-- prefix budget = 31 - unit(1) - partition(d5)
	moveq.l	#31-1,d6
	sub.l	d5,d6

;-- PREFIX: abbreviation table first
	move.l	a1,-(sp)		;save cursor across the table search
	lea	s_devAbbrevTable(pc),a2
_ssn_tbl:
	move.l	(a2),d0			;known device name ptr (0 = end)
	beq.s	_ssn_miss
	move.l	d0,a0
	move.l	BC_DevName(a4),a1
	bsr	_psStrEq		;preserves a0/a1, sets d0
	tst.l	d0
	bne.s	_ssn_hit
	lea	8(a2),a2		;next record (name ptr + abbrev ptr)
	bra.s	_ssn_tbl
_ssn_hit:
	move.l	4(a2),a0		;abbrev string
	move.l	(sp)+,a1		;restore cursor
_ssn_cpy:				;copy NUL-terminated abbrev, capped at d6
	tst.l	d6
	beq.w	_ssn_unit
	move.b	(a0)+,d0
	beq.w	_ssn_unit
	move.b	d0,(a1)+
	subq.l	#1,d6
	bra.s	_ssn_cpy

;-- PREFIX: derive from the device base name
_ssn_miss:
	move.l	(sp)+,a1		;restore cursor
	move.l	BC_DevName(a4),a0
	bsr	_scanBaseLen		;d0 = base char count (".device" stripped)
	move.l	d0,d2			;d2 = base chars remaining
	move.l	BC_DevName(a4),a0
_ssn_drv:
	tst.l	d6
	beq.s	_ssn_unit
	tst.l	d2
	beq.s	_ssn_unit
	subq.l	#1,d2
	move.b	(a0)+,d0
	bsr	_scanUpper
	cmp.b	#'0',d0			;keep only A-Z / 0-9
	blo.s	_ssn_drv
	cmp.b	#'9',d0
	bls.s	_ssn_dput
	cmp.b	#'A',d0
	blo.s	_ssn_drv
	cmp.b	#'Z',d0
	bhi.s	_ssn_drv
_ssn_dput:
	move.b	d0,(a1)+
	subq.l	#1,d6
	bra.s	_ssn_drv

;-- unit letter ('a' + unit; documented range a..p = units 0..15)
_ssn_unit:
	move.l	BC_Unit(a4),d0
	add.b	#'a',d0
	move.b	d0,(a1)+

;-- partition: 0-based decimal (1-2 digits)
	move.l	d4,d0
	cmp.l	#10,d0
	blo.s	_ssn_p1
	moveq.l	#0,d1			;d1 = tens
_ssn_pdiv:
	cmp.l	#10,d0
	blo.s	_ssn_pw
	sub.l	#10,d0
	addq.l	#1,d1
	bra.s	_ssn_pdiv
_ssn_pw:
	add.b	#'0',d1
	move.b	d1,(a1)+
_ssn_p1:
	add.b	#'0',d0
	move.b	d0,(a1)+

;-- length byte = chars written
	lea	pe_NameB(a3),a0
	move.l	a1,d0
	sub.l	a0,d0
	subq.l	#1,d0
	move.b	d0,(a0)
	movem.l	(sp)+,d0-d6/a0-a2
	rts

;===========================================================
; _scanBaseLen: length of the device name with a trailing ".device"
; removed (the leftover is the base name to derive a prefix from).
; In : a0 = device name ; Out: d0 = base char count
;===========================================================
_scanBaseLen:
	movem.l	d1/a0-a1,-(sp)
	move.l	a0,a1			;a1 = name start
	moveq.l	#0,d0
_sbl_len:
	tst.b	(a0)+
	beq.s	_sbl_end
	addq.l	#1,d0
	bra.s	_sbl_len
_sbl_end:
	cmp.l	#7,d0			;".device" is 7 chars
	bls.s	_sbl_done
	move.l	a1,a0
	add.l	d0,a0
	sub.l	#7,a0			;a0 -> last 7 chars
	lea	s_dotdevice(pc),a1
_sbl_cmp:
	move.b	(a1)+,d1
	beq.s	_sbl_strip		;matched all of ".device"
	cmp.b	(a0)+,d1
	beq.s	_sbl_cmp
	bra.s	_sbl_done
_sbl_strip:
	subq.l	#7,d0
_sbl_done:
	movem.l	(sp)+,d1/a0-a1
	rts

;-- _scanUpper: d0.b -> ASCII-uppercased
_scanUpper:
	cmp.b	#'a',d0
	blo.s	_sup_x
	cmp.b	#'z',d0
	bhi.s	_sup_x
	sub.b	#32,d0
_sup_x:
	rts

;-- abbreviation overrides: records of {APTR device name, APTR abbrev},
;   terminated by a NULL name pointer
	even
s_devAbbrevTable:
	dc.l	s_dn_compactflash,s_ab_cf
	dc.l	0,0
s_dn_compactflash:
	dc.b	"compactflash.device",0
s_ab_cf:
	dc.b	"CF",0
s_dotdevice:
	dc.b	".device",0
	even

;===========================================================
; _scanFillEnvec: synthesize a DosEnvec for a FAT hotplug node.
; The node is AUTO-DETECT: de_LowCyl = 0 (so fat95 leaves SearchMode clear and
; re-derives its partition from partition.resource on every disk-change) and
; DE_DOSTYPE = DEVICE_DOSTYPE_MARKER (so fat95 binds, and takes the partition
; selector from the node name's trailing digit). The handler thus tracks
; whatever card is inserted. The entry's pe_StartLBA/pe_BlockCount fields
; (used by ScanViaPtable to select) and pe_DosType (FAT, for the candidate
; filter + lsptres) are kept by the caller; only the node envec is synthesized
; here.
; Fake CHS: Surfaces=1, BlocksPerTrack=1 -> 1 block per cylinder.
; In : a0 = &envec, d0 = StartLBA (unused), d1 = BlockCount, d2 = DosType (unused)
;===========================================================
_scanFillEnvec:
	movem.l	d3,-(sp)
	move.l	#16,DE_TableSize*4(a0)
	move.l	#128,DE_SizeBlock*4(a0)
	clr.l	DE_SecOrg*4(a0)
	move.l	#1,DE_Surfaces*4(a0)
	move.l	#1,DE_SectorPerBlk*4(a0)
	move.l	#1,DE_BlocksPerTrk*4(a0)
	move.l	#2,DE_Reserved*4(a0)
	clr.l	DE_PreAlloc*4(a0)
	clr.l	DE_Interleave*4(a0)
	clr.l	DE_LowCyl*4(a0)		;0 -> fat95 auto-detects (no fixed geometry)
	move.l	d1,d3
	subq.l	#1,d3
	move.l	d3,DE_HighCyl*4(a0)	;informational size; ignored when auto-detect
	move.l	#30,DE_NumBuffers*4(a0)
	clr.l	DE_BufMemType*4(a0)
	move.l	#$0001FE00,DE_MaxTransfer*4(a0)
	move.l	#$7FFFFFFE,DE_Mask*4(a0)
	clr.l	DE_BOOTPRI*4(a0)
	move.l	#DEVICE_DOSTYPE_MARKER,DE_DOSTYPE*4(a0)	;device-name scheme
	movem.l	(sp)+,d3
	rts

;===========================================================
; _scanClearPresent: clear PEB_PRESENT on every entry for this device+unit.
; Step 1 of the whole-unit reconcile: a scan re-establishes PRESENT only on the
; slots the current card actually has (the publishers set it as they refresh
; each slot); _scanPurge at the end then drops the slots left not-present.
; Preserves d7 (the caller's published count).
; In : a4 = &BootCtx, a5 = ExecBase; PTR_Lock held
;===========================================================
_scanClearPresent:
	movem.l	d3/a2-a3/a6,-(sp)
	move.l	BC_Unit(a4),d3
	bsr	_partGetResource
	tst.l	d0
	beq.s	_scp_out
	move.l	d0,a2
	lea	PTR_PartList(a2),a2
	move.l	(a2),a3
_scp_walk:
	move.l	(a3),d0
	beq.s	_scp_out
	cmp.l	pe_Unit(a3),d3
	bne.s	_scp_next
	move.l	pe_Device(a3),a0
	move.l	BC_DevName(a4),a1
	bsr	_psStrEq
	tst.l	d0
	beq.s	_scp_next
	bclr	#PEB_PRESENT,pe_Flags(a3)
_scp_next:
	move.l	(a3),a3
	bra.s	_scp_walk
_scp_out:
	movem.l	(sp)+,d3/a2-a3/a6
	rts

;===========================================================
; _scanPurge: final reconcile step of a card-present scan for this device+unit.
; A present entry (card currently has this slot) is kept, re-confirmed by the
; publisher's dedup, and marked valid (PEB_INVALID cleared). A NOT-PRESENT but
; still MOUNTED entry is also kept - its DOS node + DN blob are live (pe_DevNode
; / pe_BlobPtr point at them) and only the entry tracks them - and marked
; PEB_INVALID: a card is in but it has no partition for this mounted slot.
; Only NOT-PRESENT AND NOT-MOUNTED entries are dropped here.
; In : a4 = &BootCtx, a5 = ExecBase; PTR_Lock held
;===========================================================
_scanPurge:
	movem.l	d2-d4/a2-a3/a6,-(sp)
	move.l	BC_DevName(a4),d3
	move.l	BC_Unit(a4),d4
	bsr	_partGetResource
	tst.l	d0
	beq.s	_spg_out
	move.l	d0,a2
	lea	PTR_PartList(a2),a2
	move.l	(a2),a3			;first node
_spg_walk:
	move.l	(a3),d2			;succ (capture pre-remove)
	tst.l	d2
	beq.s	_spg_out
	cmp.l	pe_Unit(a3),d4
	bne.s	_spg_next
	move.b	pe_Flags(a3),d0
	btst	#PEB_PRESENT,d0
	beq.s	_spg_chkmnt
	bclr	#PEB_INVALID,pe_Flags(a3)	;present -> valid
	bra.s	_spg_next		;keep (dedup re-confirms)
_spg_chkmnt:
	btst	#PEB_MOUNTED,d0
	beq.s	_spg_free
	bset	#PEB_INVALID,pe_Flags(a3)	;card in, slot not on it -> invalid
	bra.s	_spg_next		;keep (live node+blob)
_spg_free:
	move.l	pe_Device(a3),a0
	move.l	d3,a1
	bsr	_psStrEq
	tst.l	d0
	beq.s	_spg_next
	move.l	a5,a6
	jsr	Forbid(a6)
	move.l	a3,a1
	jsr	Remove(a6)
	jsr	Permit(a6)
	move.l	a3,a0
	bsr	_psFreeEntry
_spg_next:
	move.l	d2,a3
	bra.s	_spg_walk
_spg_out:
	movem.l	(sp)+,d2-d4/a2-a3/a6
	rts

;===========================================================
; _scanFindByIndex / _scanFindSlot: find the entry for this slot,
; matched by device + unit + ONE identity field:
;   _scanFindByIndex: pe_PartIndex - the synthesized schemes
;     (MBR/GPT/FLAT) name a slot by its index (CFa<index>), so the
;     same slot is reused across card swaps regardless of where the
;     partition starts or how big it is.
;   _scanFindSlot: pe_StartLBA - RDB carries real names; a card has
;     exactly one partition starting at a given LBA (the FS size may
;     differ from the partition size, so blockCount is NOT part of
;     the identity - same rule RegisterPartition uses).
; The publisher updates a found entry in place (refreshing geometry,
; preserving the mount overlay) instead of publishing a duplicate;
; this is the single rule that prevents double entries across card
; swaps for every scheme.
; In : d0 = partIndex / StartLBA, a4 = &BootCtx, a5 = ExecBase
; Out: d0 = matching PartEntry, or 0 if none; clobbers d1
;===========================================================
_scanFindByIndex:
	moveq.l	#pe_PartIndex,d1
	bra.s	_scanFindBy
_scanFindSlot:
	moveq.l	#pe_StartLBA,d1
_scanFindBy:
	movem.l	d2-d4/a2-a3,-(sp)
	move.l	d1,d2			;d2 = identity field offset
	move.l	d0,d4			;d4 = identity value
	move.l	BC_Unit(a4),d3
	bsr	_partGetResource
	tst.l	d0
	beq.s	_sfb_no
	move.l	d0,a2
	lea	PTR_PartList(a2),a2
	move.l	(a2),a3
_sfb_walk:
	move.l	(a3),d0
	beq.s	_sfb_no
	cmp.l	pe_Unit(a3),d3
	bne.s	_sfb_next
	cmp.l	(a3,d2.w),d4
	bne.s	_sfb_next
	move.l	pe_Device(a3),a0
	move.l	BC_DevName(a4),a1
	bsr	_psStrEq
	tst.l	d0
	bne.s	_sfb_yes
_sfb_next:
	move.l	(a3),a3
	bra.s	_sfb_walk
_sfb_yes:
	move.l	a3,d0			;return the matching entry
	movem.l	(sp)+,d2-d4/a2-a3
	rts
_sfb_no:
	moveq.l	#0,d0
	movem.l	(sp)+,d2-d4/a2-a3
	rts
