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

;===========================================================
; _scanRun: detect + publish for BC_DevName/BC_Unit.
; In : a4 = &BootCtx (unit open), a5 = ExecBase; PTR_Lock held
; Out: d0 = entries published this call
;===========================================================
_scanRun:
	movem.l	d2-d7/a2-a3/a6,-(sp)
	moveq.l	#0,d7			;d7 = published count
	clr.b	BC_ScanErr(a4)
	bsr	_scanGeometry		;block size and medium size

;-- whole-unit reconcile: once the medium is classified, PRESENT is cleared
;   for this device+unit (_scanClearPresent); the publishers re-set it on the
;   slots the current card has and _scanPurge at _srn_out drops the rest
;   (keeping mounted). A read error during the walk (BC_ScanErr) skips the
;   purge: rows the walk did not reach are left as they are, not freed.

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
	moveq.l	#9,d1			;fields read reach long index 8
	bsr	_bootBlockOK
	bne.s	_srn_rdsk_next
	moveq.l	#0,d0			;an RDB of another block size cannot
	move.b	BC_BlockShift(a4),d0	;be walked in this device's blocks
	moveq.l	#1,d1
	lsl.l	d0,d1
	cmp.l	rdb_BlockBytes(a0),d1
	beq.w	_srn_rdb
	bsr	_scanClearPresent	;an RDB disk this scan cannot walk: no
	bra.w	_srn_out		;rows, not one over the whole medium
_srn_rdsk_next:
	addq.l	#1,d6
	cmp.l	#RDB_LOCATION_LIMIT,d6
	blo.s	_srn_rdsk

;-- no RDB: classify block 0
	moveq.l	#0,d0
	bsr	_bootReadBlock
	tst.l	d0
	bne.w	_srn_rderr		;unreadable: the previous state stands
	move.l	BC_BlockBuf(a4),a0
	bsr	_partAmigaType		;an Amiga filesystem's DosType at LBA 0?
	move.l	d0,d2
	bne.w	_srn_tagged
	move.l	BC_BlockBuf(a4),a0
	bsr	_partIsBootBlock	;FAT BPB straight at LBA 0?
	tst.l	d0
	bne.w	_srn_flat
	move.l	BC_BlockBuf(a4),a0
	cmpi.w	#$55AA,510(a0)
	bne.w	_srn_whole		;no partition table
	bsr	_partIsMBR		;slot table well-formed?
	tst.l	d0
	beq.w	_srn_whole		;boot code or another volume, not a table
;-- a protective entry in any slot means GPT; a hybrid MBR mirrors only
;   some of the GPT partitions in the other slots
	move.l	BC_BlockBuf(a4),a0
	lea	446+4(a0),a1
	moveq.l	#3,d1
_srn_ee:
	cmpi.b	#$EE,(a1)
	beq.w	_srn_gpt
	lea	16(a1),a1
	dbra	d1,_srn_ee
	bra.w	_srn_mbr

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

;-- Phase 1: filesystems carried in the RDB (hop cap + self-loop guard
;   break on-disk next-pointer cycles)
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
	moveq.l	#3,d1
	bsr	_bootBlockOK
	bne.s	_srn_fs_done
	move.l	fhb_Next(a0),d3
	bsr	_bootAddOneFileSys
	cmp.l	d3,d6			;self-loop guard
	beq.s	_srn_fs_done
	bra.s	_srn_fs_loop
_srn_fs_done:

;-- Phase 2: publish partitions (hop-capped walk)
	bsr	_scanClearPresent
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
	bne.w	_srn_rderr
	move.l	BC_BlockBuf(a4),a0
	cmpi.l	#PART_ID,(a0)
	bne.w	_srn_out
	moveq.l	#3,d1
	bsr	_bootBlockOK
	bne.w	_srn_out		;torn block: the chain ends here
	move.l	pb_Next(a0),d3
	bsr	_scanPubRDB		;d5 = index; buffer = PART block
	add.l	d0,d7
	addq.l	#1,d5
	cmp.l	d3,d6
	beq.w	_srn_out
	bra.s	_srn_pt_loop

;- - whole medium: one entry over the device - - - - - - - -
;   Block 0 with an Amiga DosType gives a row of that DosType over the whole
;   medium. Any other block 0 without a partition table, FAT boot block or
;   not, gives one FAT row; the handler bound to the node reads block 0 and
;   decides.
_srn_tagged:
	PTMSG	dbg_pt_tagged
	bra.s	_srn_pubflat
_srn_whole:
	PTMSG	dbg_pt_whole
	ifd	DEBUG
	bra.s	_srn_fatflat
	endc
_srn_flat:
	PTMSG	dbg_pt_flat
_srn_fatflat:
	move.l	#DOSTYPE_FAT,d2
_srn_pubflat:
	bsr	_scanClearPresent
	move.l	BC_Medium(a4),d1	;d1 = medium size, 0 = unknown
	bsr	_scanPubFlat		;d1 = size, d2 = DosType
	add.l	d0,d7
	bra.w	_srn_out

;- - MBR / GPT: walker -> PartRec[] -> publish - - - - - - -
_srn_mbr:
	PTMSG	dbg_pt_mbr
	moveq.l	#PES_MBR,d6
	bra.s	_srn_table
_srn_gpt:
	PTMSG	dbg_pt_gpt
	moveq.l	#PES_GPT,d6
_srn_table:
	move.l	#PART_MAX_REC*PR_Sizeof,d0
	moveq.l	#MEMF_PUBLIC,d1
	move.l	a5,a6
	jsr	AllocMem(a6)
	tst.l	d0
	beq.w	_srn_rderr		;not walked: keep the rows as they are
	move.l	d0,a2			;a2 = PartRec buffer
	move.l	BC_BlockBuf(a4),a0	;block 0 for the MBR walker
	lea	_psReadLBA(pc),a3	;EBR / GPT block reader
	cmp.b	#PES_GPT,d6
	beq.s	_srn_walkgpt
	bsr	_partScanMBR
	bra.s	_srn_pubrecs
_srn_walkgpt:
	moveq.l	#0,d1
	move.b	BC_BlockShift(a4),d1
	bsr	_partScanGPT
_srn_pubrecs:
	move.l	d0,d5			;d5 = record count
	tst.b	BC_ScanErr(a4)		;table not read in full: keep the
	bne.s	_srn_pr_keep		;rows it did not reach as they are
	bsr	_scanClearPresent
_srn_pr_keep:
	moveq.l	#0,d4			;d4 = record index
_srn_pr_loop:
	cmp.l	d5,d4
	bhs.s	_srn_pr_done
	move.l	d4,d0
	mulu.w	#PR_Sizeof,d0
	lea	0(a2,d0.l),a3		;a3 = &PartRec[d4]
	bsr	_scanPubRec		;a3 = &PartRec, d6 = source
	add.l	d0,d7
	addq.l	#1,d4
	bra.s	_srn_pr_loop
_srn_pr_done:
	move.l	a2,a1
	move.l	#PART_MAX_REC*PR_Sizeof,d0
	move.l	a5,a6
	jsr	FreeMem(a6)
	bra.s	_srn_out
_srn_rderr:
	st	BC_ScanErr(a4)
_srn_out:
;-- drop slots the current card no longer has (PRESENT still clear after the
;   reconcile): mounted ones are kept (shown absent ---M), unmounted
;   published-only ones are freed. Preserves d7 (the published count).
	tst.b	BC_ScanErr(a4)
	bne.s	_srn_nopurge
	bsr	_scanPurge
_srn_nopurge:
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
;   start = LowCyl * cylblocks; count = (HighCyl-LowCyl+1) * cylblocks.
;   A start past 32 bits cannot serve as the key: not published. A count
;   reaching past 32 bits is cut at the last 32-bit block.
	move.l	pb_Environment+DE_Surfaces*4(a2),d0
	move.l	pb_Environment+DE_BlocksPerTrk*4(a2),d1
	UMUL32
	bvs.w	_spr_skip
	move.l	d0,d4			;d4 = cylblocks
	move.l	pb_Environment+DE_LowCyl*4(a2),d0
	move.l	d4,d1
	UMUL32
	bvs.w	_spr_skip
	move.l	d0,d6			;d6 = start
	move.l	pb_Environment+DE_HighCyl*4(a2),d0
	sub.l	pb_Environment+DE_LowCyl*4(a2),d0
	bcs.w	_spr_skip		;HighCyl below LowCyl
	addq.l	#1,d0
	beq.s	_spr_cut
	move.l	d4,d1
	UMUL32
	bvs.s	_spr_cut
	move.l	d0,d4			;d4 = block count
	subq.l	#1,d0
	add.l	d6,d0
	bcc.s	_spr_key		;last block fits 32 bits
_spr_cut:
	move.l	d6,d4
	not.l	d4			;last block $FFFFFFFE
_spr_key:

;-- same slot already present (rescan / card swap)?  refresh it in place
	bsr	_scanFindRDB
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
	move.b	pe_Flags(a3),d0		;preserve MOUNTED + policy bits
	and.b	#(1<<PEB_MOUNTED)|(1<<PEB_KEEPSTATIC)|(1<<PEB_MOUNTUSED),d0
	or.b	d1,d0
	move.b	d0,pe_Flags(a3)
	move.l	pb_Environment+DE_BOOTPRI*4(a2),pe_BootPri(a3)
	move.l	pb_Environment+DE_DOSTYPE*4(a2),pe_DosType(a3)
;-- RDB rows count blocks of the envec's SizeBlock; its log2 when that is a
;   power of two, else 0 (unknown)
	moveq.l	#0,d0
	move.l	pb_Environment+DE_SizeBlock*4(a2),d1
	beq.s	_frd_bs
	moveq.l	#1,d0			;SizeBlock counts longs: +2
_frd_bsl:
	addq.l	#1,d0
	lsr.l	#1,d1
	bcc.s	_frd_bsl
	beq.s	_frd_bs			;no bit left above the lowest
	moveq.l	#0,d0			;more than one bit set
_frd_bs:
	move.b	d0,pe_BlockShift(a3)
	lea	pb_Environment(a2),a0
	lea	pe_Envec(a3),a1
	move.l	d2,d3
	addq.l	#1,d3
	cmp.l	#21,d3			;pe_Envec holds 21 longs. Defensive
	bls.s	_frd_ecp		;only: the publisher already skips
	moveq.l	#21,d3			;partitions with TableSize > 20
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
	move.b	PR_PartIndex(a2),d0	;identity = partition index (CF<index>)
	move.l	PR_DosType(a2),d2
	move.l	PR_BlockCount(a2),d3
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
	move.b	pe_Flags(a3),d2		;preserve MOUNTED + policy bits
	and.b	#(1<<PEB_MOUNTED)|(1<<PEB_KEEPSTATIC)|(1<<PEB_MOUNTUSED),d2
	or.b	d1,d2
	move.b	d2,pe_Flags(a3)
	move.l	PR_DosType(a2),pe_DosType(a3)
	move.b	BC_BlockShift(a4),pe_BlockShift(a3)
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
; _scanGeometry: TD_GETGEOMETRY -> BC_BlockShift and BC_Medium.
; A sector size of 512, 1024, 2048 or 4096 bytes sets the block shift; an
; unset one (0) means 512. A failed command or any other size leaves 512
; and an unknown medium size.
; In : a4 = &BootCtx (unit open), a5 = ExecBase. Clobbers d0-d2.
;===========================================================
_scanGeometry:
	moveq.l	#9,d1			;d1 = shift
	moveq.l	#0,d2			;d2 = medium blocks
	bsr	_bootGeometry
	tst.l	d0
	bne.s	_sgeo_set
	move.l	BC_Geometry+DG_TotalSectors(a4),d2
	move.l	BC_Geometry+DG_SectorSize(a4),d0
	beq.s	_sgeo_set		;unset: the driver works in 512-byte blocks
_sgeo_find:				;halve the size down to 512, counting
	cmp.l	#512,d0
	beq.s	_sgeo_set
	bcs.s	_sgeo_bad		;below 512
	btst	#0,d0
	bne.s	_sgeo_bad		;not a power of two
	lsr.l	#1,d0
	addq.l	#1,d1
	cmp.l	#12,d1
	bls.s	_sgeo_find
_sgeo_bad:
	moveq.l	#9,d1			;unsupported size: 512, size unknown
	moveq.l	#0,d2
_sgeo_set:
	move.b	d1,BC_BlockShift(a4)
	move.l	d2,BC_Medium(a4)
	rts

;===========================================================
; _scanPubFlat: publish the whole-medium entry.
; In : d1 = size in blocks (0 = unknown), d2 = DosType, a4, a5
; Out: d0 = 1 published / 0 failed
;===========================================================
_scanPubFlat:
	movem.l	d2-d3/a2-a3,-(sp)
	move.l	d1,d3			;d3 = total sectors
;-- a row of another DosType has a fixed window, which needs the size
	move.l	d2,d0
	clr.b	d0
	cmp.l	#DOSTYPE_FAT,d0
	beq.s	_spf_sized
	tst.l	d3
	beq.s	_spf_fail
_spf_sized:

;-- same slot (whole medium = index 0) already present?  refresh it in place
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
; _scanFillFlat: write the whole-medium geometry into an entry.
; In : a3 = entry, d2 = DosType, d3 = size in blocks, a4, a5. Sets
; PEB_PRESENT, preserves PEB_MOUNTED; leaves the mount overlay intact.
;===========================================================
_scanFillFlat:
	clr.l	pe_PartIndex(a3)
	move.b	#PES_FLAT,pe_Source(a3)
;-- rebuild flags, preserving only PEB_MOUNTED + the policy bits (as
;   _scanFillRec does): stale BOOTABLE/NOMOUNT bits from a previous card
;   must not survive the refresh
	move.b	pe_Flags(a3),d0
	and.b	#(1<<PEB_MOUNTED)|(1<<PEB_KEEPSTATIC)|(1<<PEB_MOUNTUSED),d0
	or.b	#1<<PEB_PRESENT,d0
	move.b	d0,pe_Flags(a3)
	move.l	d2,pe_DosType(a3)
	move.b	BC_BlockShift(a4),pe_BlockShift(a3)
	clr.l	pe_StartLBA(a3)
	move.l	d3,pe_BlockCount(a3)
	lea	pe_Envec(a3),a0
	moveq.l	#0,d0			;start
	move.l	d3,d1			;count
	bsr	_scanFillEnvec
;-- not FAT: the node carries the DosType, LowCyl 0..HighCyl is the medium
	move.l	d2,d0
	clr.b	d0
	cmp.l	#DOSTYPE_FAT,d0
	beq.s	_sff_name
	move.l	d2,DE_DOSTYPE*4(a0)
_sff_name:
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
; Name = PREFIX + [unit] + partition
;   PREFIX  abbreviation table value, else the device base name (trailing
;           ".device" stripped, kept A-Z/0-9 uppercased), truncated to fit
;   unit    lowercase letter 'a' + unit (a..p for units 0..15); omitted
;           for unit 0 of a table entry flagged DABF_NOUNIT (single-unit
;           device)
;   part    decimal partition index, 0-based
; e.g. compactflash.device unit 0 -> CF0 CF1 CF2   (table -> CF, no unit)
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
	blo.s	_ssn_pref
	addq.l	#1,d5
_ssn_pref:

;-- PREFIX: abbreviation table first (d3 = 1 while the unit letter is kept)
	moveq.l	#1,d3
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
	lea	12(a2),a2		;next record (name + abbrev + flags)
	bra.s	_ssn_tbl
_ssn_hit:
;-- single-unit device: omit the unit letter. Unit 0 only; a nonzero unit
;   on such a device keeps its letter so the names stay unique.
	move.l	8(a2),d0		;record flags
	btst	#DABF_NOUNIT,d0
	beq.s	_ssn_budget
	tst.l	BC_Unit(a4)
	bne.s	_ssn_budget
	moveq.l	#0,d3
_ssn_budget:
;-- prefix budget = 31 - unit letter (d3: 0 or 1) - partition (d5)
	moveq.l	#31,d6
	sub.l	d3,d6
	sub.l	d5,d6
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
;-- prefix budget = 31 - unit(1) - partition(d5)
	moveq.l	#31-1,d6
	sub.l	d5,d6
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

;-- unit letter ('a' + unit; documented range a..p = units 0..15),
;   suppressed when the table flagged this device DABF_NOUNIT (d3 = 0)
_ssn_unit:
	tst.l	d3
	beq.s	_ssn_part
	move.l	BC_Unit(a4),d0
	add.b	#'a',d0
	move.b	d0,(a1)+
_ssn_part:

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

;-- abbreviation overrides: records of {APTR device name, APTR abbrev,
;   LONG flags}, terminated by a NULL name pointer
DABF_NOUNIT = 0		;flag bit: single-unit device, omit the unit letter
	even
s_devAbbrevTable:
	dc.l	s_dn_compactflash,s_ab_cf,1<<DABF_NOUNIT
	dc.l	0
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
; Fake CHS: Surfaces=1, BlocksPerTrack=1 -> 1 device block per cylinder.
; In : a0 = &envec, d0 = StartLBA (unused), d1 = BlockCount, d2 = DosType
;      (unused), a4 = &BootCtx (BC_BlockShift)
;===========================================================
_scanFillEnvec:
	movem.l	d3-d4,-(sp)
	move.l	#16,DE_TableSize*4(a0)
	moveq.l	#0,d4
	move.b	BC_BlockShift(a4),d4
	moveq.l	#1,d3
	lsl.l	d4,d3			;d3 = block size
	move.l	d3,d4
	lsr.l	#2,d4
	move.l	d4,DE_SizeBlock*4(a0)	;in longs
	neg.l	d3
	and.l	#$0001FE00,d3		;largest transfer, whole blocks
	move.l	d3,DE_MaxTransfer*4(a0)
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
	move.l	#$7FFFFFFE,DE_Mask*4(a0)
	clr.l	DE_BOOTPRI*4(a0)
	move.l	#DEVICE_DOSTYPE_MARKER,DE_DOSTYPE*4(a0)	;device-name scheme
	movem.l	(sp)+,d3-d4
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
	move.l	pe_Device(a3),a0	;same unit NUMBER is not the same unit:
	move.l	d3,a1			;another device's entries must not have
	bsr	_psStrEq		;their PRESENT/INVALID state touched
	tst.l	d0
	beq.s	_spg_next
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
	bsr	_psUnlinkFreeEntry
_spg_next:
	move.l	d2,a3
	bra.s	_spg_walk
_spg_out:
	movem.l	(sp)+,d2-d4/a2-a3/a6
	rts

;===========================================================
; _scanFindRDB: the RDB entry to refresh for the PART block at a2.
; Matched by device + unit + pe_StartLBA: a card has one partition
; starting at a given block. Among those, the entry whose envec window
; and DosType equal the block's is taken; else an unmounted one, which
; is refreshed in place. A mounted entry with another window is never
; refreshed: its node keeps the old geometry, so the entry is left to the
; purge (MOUNTED + INVALID) and the partition gets a new entry.
; In : a2 = PART block, d6 = start block, a4 = &BootCtx, a5 = ExecBase
; Out: d0 = entry, or 0 for a new one; clobbers d1
;===========================================================
_scanFindRDB:
	movem.l	d2-d3/a0-a1/a3,-(sp)
	moveq.l	#0,d3			;d3 = unmounted entry to fall back on
	move.l	BC_Unit(a4),d2
	bsr	_partGetResource
	tst.l	d0
	beq.s	_sfr_out
	move.l	d0,a3
	move.l	PTR_PartList(a3),a3
_sfr_walk:
	tst.l	(a3)
	beq.s	_sfr_end
	cmp.l	pe_Unit(a3),d2
	bne.s	_sfr_next
	cmp.l	pe_StartLBA(a3),d6
	bne.s	_sfr_next
	cmp.b	#PES_RDB,pe_Source(a3)
	bne.s	_sfr_next
	move.l	pe_Device(a3),a0
	move.l	BC_DevName(a4),a1
	bsr	_psStrEq
	tst.l	d0
	beq.s	_sfr_next
	lea	pe_Envec(a3),a0
	lea	pb_Environment(a2),a1
	moveq.l	#DE_SizeBlock*4,d0
	bsr.s	_sfr_cmp
	moveq.l	#DE_Surfaces*4,d0
	bsr.s	_sfr_cmp
	moveq.l	#DE_BlocksPerTrk*4,d0
	bsr.s	_sfr_cmp
	moveq.l	#DE_LowCyl*4,d0
	bsr.s	_sfr_cmp
	moveq.l	#DE_HighCyl*4,d0
	bsr.s	_sfr_cmp
	moveq.l	#DE_DOSTYPE*4,d0
	bsr.s	_sfr_cmp
	move.l	a3,d0			;same partition: refresh this one
	bra.s	_sfr_out
_sfr_differs:
	addq.l	#4,sp			;drop the _sfr_cmp return address
	btst	#PEB_MOUNTED,pe_Flags(a3)
	bne.s	_sfr_next		;its node has the old geometry
	tst.l	d3
	bne.s	_sfr_next
	move.l	a3,d3
_sfr_next:
	move.l	(a3),a3
	bra.s	_sfr_walk
_sfr_end:
	move.l	d3,d0
_sfr_out:
	movem.l	(sp)+,d2-d3/a0-a1/a3
	rts
;-- _sfr_cmp: envec long at offset d0 equal in a0 and a1, else leave
;   through _sfr_differs
_sfr_cmp:
	move.l	(a0,d0.w),d1
	cmp.l	(a1,d0.w),d1
	bne.s	_sfr_differs
	rts

;===========================================================
; _scanFindByIndex: find the entry for this slot, matched by device +
; unit + pe_PartIndex: the synthesized schemes (MBR/GPT/FLAT) name a
; slot by its index (CF<index>), so the same slot is reused across card
; swaps regardless of where the partition starts or how big it is. The
; publisher updates a found entry in place (refreshing geometry,
; preserving the mount overlay) instead of publishing a duplicate.
; A mounted entry is reused only when its node fits the new partition:
; the same DosType, and for a DosType other than FAT (a fixed window) the
; same size. Else an unmounted entry is taken, or none; the mounted one is
; left to the purge (MOUNTED + INVALID).
; In : d0 = partIndex, d2 = DosType, d3 = size in blocks, a4, a5
; Out: d0 = matching PartEntry, or 0 if none; clobbers d1/a0/a1
;===========================================================
_scanFindByIndex:
	movem.l	d2-d6/a2-a3,-(sp)
	move.l	d0,d4			;d4 = partition index
	moveq.l	#0,d6			;d6 = unmounted entry to fall back on
	move.l	BC_Unit(a4),d5
	bsr	_partGetResource
	tst.l	d0
	beq.s	_sfb_end
	move.l	d0,a2
	lea	PTR_PartList(a2),a2
	move.l	(a2),a3
_sfb_walk:
	move.l	(a3),d0
	beq.s	_sfb_end
	cmp.l	pe_Unit(a3),d5
	bne.s	_sfb_next
	cmp.l	pe_PartIndex(a3),d4
	bne.s	_sfb_next
;-- an RDB entry is refreshed only by the RDB publisher, or a card swap that
;   changes the scheme would rewrite a mounted entry of the other kind in
;   place instead of leaving it to the purge (kept as MOUNTED+INVALID)
	cmp.b	#PES_RDB,pe_Source(a3)
	beq.s	_sfb_next
	move.l	pe_Device(a3),a0
	move.l	BC_DevName(a4),a1
	bsr	_psStrEq
	tst.l	d0
	beq.s	_sfb_next
	btst	#PEB_MOUNTED,pe_Flags(a3)
	bne.s	_sfb_mounted
	tst.l	d6
	bne.s	_sfb_next
	move.l	a3,d6
	bra.s	_sfb_next
_sfb_mounted:
	cmp.l	pe_DosType(a3),d2
	bne.s	_sfb_next		;its node serves another filesystem
	move.l	d2,d0
	clr.b	d0
	cmp.l	#DOSTYPE_FAT,d0
	beq.s	_sfb_yes		;auto-detect node: follows the card
	cmp.l	pe_BlockCount(a3),d3
	beq.s	_sfb_yes		;same window
_sfb_next:
	move.l	(a3),a3
	bra.s	_sfb_walk
_sfb_yes:
	move.l	a3,d0			;return the matching entry
	movem.l	(sp)+,d2-d6/a2-a3
	rts
_sfb_end:
	move.l	d6,d0
	movem.l	(sp)+,d2-d6/a2-a3
	rts
