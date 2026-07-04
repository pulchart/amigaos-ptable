;===========================================================
; parts.s - context-free MBR / GPT partition walker
;
; Parses the four primary MBR slots and the GPT primary header
; into a caller-supplied buffer of PartRec. Holds no globals:
; the caller passes a 512-byte block-reader callback and the
; output buffer. 512-byte sectors are assumed (CF cards).
;
; ptable.library includes this; fat95 reaches it at runtime via
; the ScanPartitions LVO (it does not include this file).
;===========================================================

	include	"parts.i"
	include	"umul32.i"
	include	"log2.i"

;-- REVL reg: reverse the 4 bytes of a longword (LE<->BE).
;   68000-safe (no byte-reverse opcode): rol.w/swap/rol.w.
REVL	macro
	rol.w	#8,\1
	swap	\1
	rol.w	#8,\1
	endm

;===========================================================
; _partScanMBR - parse the four primary slots of a loaded MBR.
;
; Input : a0 = &block 0 (512 bytes, $55AA already verified;
;              slot-0 type already known != $EE), a2 = &PartRec
;              output buffer (PART_MAX_REC * PR_Sizeof)
; Output: d0 = record count
; Preserves d2-d7/a3-a6 (a0/a1 scratch).
;===========================================================
_partScanMBR:
	movem.l	d2-d6/a3,-(sp)
	moveq.l	#0,d6			;d6 = record count
	lea	446(a0),a3		;a3 = &slot 0
	moveq.l	#0,d4			;d4 = slot index 0..3
_psm_slot:
	move.b	4(a3),d0		;partition type byte
	bsr	_psm_isfat
	tst.l	d0
	beq.s	_psm_next
	move.l	8(a3),d0		;relative start LBA (LE)
	REVL	d0
	move.l	12(a3),d1		;sector count (LE)
	REVL	d1
	tst.l	d1			;zero-size slot -> skip
	beq.s	_psm_next
	move.l	d6,d2
	mulu.w	#PR_Sizeof,d2
	lea	0(a2,d2.l),a1		;a1 = &PartRec[d6]
	move.l	d0,PR_StartLBA(a1)
	move.l	d1,PR_BlockCount(a1)
	move.l	#DOSTYPE_FAT,PR_DosType(a1)
	move.b	d4,PR_PartIndex(a1)
	moveq.l	#1<<PRFB_PRESENT,d3
	cmpi.b	#$80,(a3)		;status byte: active/bootable
	bne.s	_psm_nb
	bset	#PRFB_BOOTABLE,d3
_psm_nb:
	move.b	d3,PR_Flags(a1)
	addq.l	#1,d6
	cmp.l	#PART_MAX_REC,d6
	bhs.s	_psm_done
_psm_next:
	lea	16(a3),a3
	addq.l	#1,d4
	cmp.l	#4,d4
	blo.s	_psm_slot
_psm_done:
	move.l	d6,d0
	movem.l	(sp)+,d2-d6/a3
	rts

;-- _psm_isfat: d0 = type byte in; d0 = 1 if FAT type else 0.
;   Whitelist 01/04/06 (FAT12/16) and 0b/0c/0e (FAT32/LBA).
_psm_isfat:
	cmpi.b	#$01,d0
	beq.s	_psm_yes
	cmpi.b	#$04,d0
	beq.s	_psm_yes
	cmpi.b	#$06,d0
	beq.s	_psm_yes
	cmpi.b	#$0b,d0
	beq.s	_psm_yes
	cmpi.b	#$0c,d0
	beq.s	_psm_yes
	cmpi.b	#$0e,d0
	beq.s	_psm_yes
	moveq.l	#0,d0
	rts
_psm_yes:
	moveq.l	#1,d0
	rts

;===========================================================
; _partScanGPT - walk the GPT primary header + entry array.
;
; Input : a2 = &PartRec output buffer, a3 = block-reader callback
;              (d0 = block LBA -> d0 = 0 on success & a0 = &512B
;               buffer; preserves d2-d7), a4 = callback context
; Output: d0 = record count
; Preserves d2-d7/a4-a6 (a0/a1/a5 scratch).
;===========================================================
_partScanGPT:
	movem.l	d2-d7/a5,-(sp)
	moveq.l	#0,d7			;d7 = record count
;-- read LBA 1 (GPT header)
	moveq.l	#1,d0
	jsr	(a3)
	tst.l	d0
	bne.w	_psg_done
	move.l	a0,a1			;a1 = &GPT header
	cmpi.l	#"EFI ",(a1)
	bne.w	_psg_done
	cmpi.l	#"PART",4(a1)
	bne.w	_psg_done
	move.l	72(a1),d4		;PartitionEntryLBA low (LE)
	REVL	d4
	move.l	76(a1),d0		;..high
	tst.l	d0
	bne.w	_psg_done		;beyond 32-bit
	move.l	80(a1),d5		;NumberOfPartitionEntries (LE)
	REVL	d5
	move.l	84(a1),d6		;SizeOfPartitionEntry (LE)
	REVL	d6
	tst.w	d6
	beq.w	_psg_done
;-- iterate entries 0..d5-1
	moveq.l	#0,d2			;d2 = entry index
_psg_eloop:
	cmp.l	d5,d2
	bhs.w	_psg_done
	cmp.l	#PART_MAX_REC,d7
	bhs.w	_psg_done
;-- byte offset = idx * entrySize; 512-byte sectors -> block = base
;   + offset>>9, rem = offset & 511
	move.l	d2,d0
	move.l	d6,d1
	UMUL32				;d0 = idx * entrySize
	move.l	d0,d3
	andi.l	#$1ff,d3		;d3 = byte offset within block (kept
					;     across the callback: preserved reg)
	lsr.l	#8,d0
	lsr.l	#1,d0			;d0 = offset / 512
	add.l	d4,d0			;d0 = absolute LBA of the entry block
	jsr	(a3)
	tst.l	d0
	bne.w	_psg_done
	move.l	a0,a1
	add.l	d3,a1			;a1 = &partition entry
	tst.l	(a1)			;type GUID all-zero -> unused
	beq.w	_psg_enext
;-- compare 16-byte type GUID against the FAT-carrying table
	lea	_psg_guids(pc),a5
	moveq.l	#1,d0			;outer: 2 GUIDs (0-based dbra)
_psg_cmp_outer:
	move.l	a1,a0			;reset entry-GUID scan cursor
	moveq.l	#3,d1			;inner: 4 longs / GUID
_psg_cmp_inner:
	cmpm.l	(a0)+,(a5)+
	dbne	d1,_psg_cmp_inner	;continue while equal
	beq.s	_psg_match		;all 4 matched
	lsl.l	#2,d1			;bytes left in this table GUID
	add.l	d1,a5			;skip to next table GUID
	dbra	d0,_psg_cmp_outer
	bra.w	_psg_enext
_psg_match:
	move.l	32(a1),d0		;First LBA low (LE)
	REVL	d0
	move.l	36(a1),d1		;First LBA high
	bne.s	_psg_enext		;beyond 32-bit
	move.l	d0,d3			;save first LBA
	move.l	40(a1),d0		;Last LBA low (LE)
	REVL	d0
	move.l	44(a1),d1		;Last LBA high
	bne.s	_psg_enext
	sub.l	d3,d0
	addq.l	#1,d0			;d0 = last - first + 1 = block count
	move.l	d7,d1
	mulu.w	#PR_Sizeof,d1
	lea	0(a2,d1.l),a0		;a0 = &PartRec[d7]
	move.l	d3,PR_StartLBA(a0)
	move.l	d0,PR_BlockCount(a0)
	move.l	#DOSTYPE_FAT,PR_DosType(a0)
	move.b	d2,PR_PartIndex(a0)
	moveq.l	#(1<<PRFB_PRESENT)|(1<<PRFB_GPT),d1
	move.b	d1,PR_Flags(a0)
	addq.l	#1,d7
_psg_enext:
	addq.l	#1,d2
	bra.w	_psg_eloop
_psg_done:
	move.l	d7,d0
	movem.l	(sp)+,d2-d7/a5
	rts

;-- FAT-carrying GPT type GUIDs, byte-swapped for word-aligned cmp.l
;   EBD0A0A2-B9E5-4433-87C0-68B6B72699C7  Microsoft Basic Data
;   C12A7328-F81F-11D2-BA4B-00A0C93EC93B  EFI System Partition
_psg_guids:
	dc.l	$A2A0D0EB,$E5B93344,$87C068B6,$B72699C7
	dc.l	$28732AC1,$1FF8D211,$BA4B00A0,$C93EC93B

;===========================================================
; _partIsBootBlock - FAT boot-sector sanity gate (rejects NTFS).
;
; Input : a0 = &block (512 bytes)
; Output: d0 = -1 (looks like a FAT boot block) or 0
; Clobbers d0/d1 (caller saves what it needs).
;===========================================================
_partIsBootBlock:
	move.l	(a0),d1
	cmpi.b	#$e9,(a0)		;i80x86 word branch
	beq.s	_pib_bscheck
	andi.l	#$ff80ff00,d1
	cmpi.l	#$eb009000,d1		;i80x86 byte branch + NOP
	bne.s	_pib_error
	move.b	1(a0),d1
	beq.s	_pib_bscheck		;PalmOS card without boot code
	cmpi.b	#36,d1
	blt.s	_pib_error		;..at least past the parameter block
_pib_bscheck:
;-- reject NTFS ("NTFS    " OEM ID at offset 3); 3(a0) is odd, so
;   test the byte first then the aligned long.
	cmpi.b	#'N',3(a0)
	bne.s	_pib_not_ntfs
	cmpi.l	#"TFS ",4(a0)
	beq.s	_pib_error
_pib_not_ntfs:
	moveq.l	#0,d1
	move.b	13(a0),d1		;blocks/cluster..
	beq.s	_pib_error		;..is null..
	move.l	d1,d0
	LOG2
	bclr	d0,d1
	tst.l	d1
	bne.s	_pib_error		;..or not a power of 2
	move.b	12(a0),d1
	lsl.w	#8,d1
	move.b	11(a0),d1		;logical block size..
	move.l	d1,d0
	LOG2
	cmp.w	#9,d0
	bcs.s	_pib_error		;..< 512,..
	cmp.w	#13,d0
	bcc.s	_pib_error		;..> 4096,..
	bclr	d0,d1
	tst.l	d1
	bne.s	_pib_error		;..or not a power of 2
	moveq.l	#-1,d0			;OK
	rts
_pib_error:
	moveq.l	#0,d0
	rts
