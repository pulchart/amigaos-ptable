;===========================================================
; parts.s - context-free MBR / GPT partition walker
;
; Parses the MBR (primary slots and the EBR chain) and the GPT primary header
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
; _partScanMBR - parse the four primary slots of a loaded MBR, then
; the EBR chain of the first extended slot (logicals indexed 4..).
;
; Input : a0 = &block 0 (512 bytes, $55AA already verified;
;              slot-0 type already known != $EE), a2 = &PartRec
;              output buffer (PART_MAX_REC * PR_Sizeof),
;         a3 = block-reader callback (as _partScanGPT; it may
;              overwrite the block 0 buffer), a4 = callback context
; Output: d0 = record count
; Preserves d2-d7/a2-a6 (a0/a1 scratch).
;===========================================================
_partScanMBR:
	movem.l	d2-d7/a2/a5,-(sp)	;a2 advances as the output cursor
	moveq.l	#0,d6			;d6 = record count
	moveq.l	#0,d5			;d5 = extended start LBA (0 = none)
	moveq.l	#0,d2			;d2 = base LBA: primaries are absolute
	lea	446(a0),a5		;a5 = &slot 0
	moveq.l	#0,d4			;d4 = slot index 0..3
_psm_slot:
	cmp.l	#PART_MAX_REC,d6
	bhs.w	_psm_done
	move.b	4(a5),d0
	lea	_psm_ext(pc),a1
	bsr	_psm_intype
	bne.s	_psm_prim
	tst.l	d5
	bne.s	_psm_next		;only the first extended slot is followed
	tst.l	12(a5)
	beq.s	_psm_next		;zero-size extended slot
	move.l	8(a5),d5
	REVL	d5
	bra.s	_psm_next
_psm_prim:
	bsr	_psm_add
_psm_next:
	lea	16(a5),a5
	addq.l	#1,d4
	cmp.l	#4,d4
	blo.s	_psm_slot

;-- logicals: each EBR holds one logical (entry 0, relative to the EBR)
;   and a link to the next EBR (entry 1, relative to the extended start)
	tst.l	d5
	beq.s	_psm_done
	move.l	d5,d7			;d7 = current EBR LBA
_psm_ebr:
	cmp.l	#PART_MAX_REC,d6
	bhs.s	_psm_done
	cmp.l	#100,d4			;same two-digit index budget as GPT
	bhs.s	_psm_done
	move.l	d7,d0
	jsr	(a3)
	tst.l	d0
	bne.s	_psm_done
	cmpi.w	#$55AA,510(a0)
	bne.s	_psm_done
	lea	446(a0),a5		;a5 = entry 0: the logical
	move.l	d7,d2
	bsr	_psm_add
	tst.l	12(a5)
	beq.s	_psm_link		;empty entry takes no index
	addq.l	#1,d4
_psm_link:
	lea	16(a5),a5		;a5 = entry 1: link to the next EBR
	move.b	4(a5),d0
	lea	_psm_ext(pc),a1
	bsr	_psm_intype
	bne.s	_psm_done
	move.l	8(a5),d0
	REVL	d0
	tst.l	d0
	beq.s	_psm_done
	add.l	d5,d0
	bcs.s	_psm_done		;do not read a wrapped LBA
	cmp.l	d7,d0
	bls.s	_psm_done		;chain must ascend: breaks link cycles
	move.l	d0,d7
	bra.s	_psm_ebr
_psm_done:
	move.l	d6,d0
	movem.l	(sp)+,d2-d7/a2/a5
	rts

;-- _psm_add: record the slot at a5 when FAT-typed and non-empty.
;   In: a5 = &slot, d2 = base LBA, d4 = index, d6 = count, a2 = &next PartRec
;   Out: d6/a2 advanced on a record. Clobbers d0/d1/d3/a1.
_psm_add:
	move.b	4(a5),d0
	lea	_psm_fat(pc),a1
	bsr	_psm_intype
	bne.s	_psa_out
	move.l	12(a5),d1		;sector count (LE)
	REVL	d1
	tst.l	d1			;zero-size slot -> skip
	beq.s	_psa_out
	move.l	8(a5),d0		;relative start LBA (LE)
	REVL	d0
	add.l	d2,d0
	bcs.s	_psa_out		;start beyond 32 bits
	move.l	d0,PR_StartLBA(a2)
	move.l	d1,PR_BlockCount(a2)
	move.l	#DOSTYPE_FAT,PR_DosType(a2)
	move.b	d4,PR_PartIndex(a2)
	moveq.l	#1<<PRFB_PRESENT,d3
	cmpi.b	#$80,(a5)		;status byte: active/bootable
	bne.s	_psa_nb
	bset	#PRFB_BOOTABLE,d3
_psa_nb:
	move.b	d3,PR_Flags(a2)
	lea	PR_Sizeof(a2),a2
	addq.l	#1,d6
_psa_out:
	rts

;-- _psm_intype: d0 = type byte, a1 = 0-terminated type list; Z set if
;   listed. Clobbers d1/a1.
_psm_intype:
	move.b	(a1)+,d1
	beq.s	_psm_it_no
	cmp.b	d1,d0
	bne.s	_psm_intype
	rts				;Z set: listed
_psm_it_no:
	moveq.l	#1,d1			;Z clear: not listed
	rts

;-- MBR type bytes: FAT12/16 01/04/06, FAT32 0b/0c, FAT16 LBA 0e;
;   extended CHS 05, LBA 0f, Linux 85
_psm_fat:	dc.b	$01,$04,$06,$0b,$0c,$0e,0
_psm_ext:	dc.b	$05,$0f,$85,0
	even

;===========================================================
; _partScanGPT - walk the GPT primary header + entry array.
;
; Input : a2 = &PartRec output buffer, a3 = block-reader callback
;              (d0 = block LBA -> d0 = 0 on success & a0 = &512B
;               buffer; preserves d2-d7/a2-a4), a4 = callback context
; Output: d0 = record count
; Preserves d2-d7/a2-a6 (a0/a1 scratch).
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
;-- disk-supplied: accept only >= 128 and a multiple of 128 (UEFI: 128*2^n),
;   or entries straddle the 512-byte buffer / land on odd addresses
	move.l	d6,d0
	and.l	#$7F,d0
	bne.w	_psg_done
	cmp.l	#128,d6
	blo.w	_psg_done
;-- iterate entries 0..d5-1
	moveq.l	#0,d2			;d2 = entry index
_psg_eloop:
	cmp.l	d5,d2
	bhs.w	_psg_done
	cmp.l	#100,d2			;PR_PartIndex is a byte and the node name
	bhs.w	_psg_done		;budgets two digits: entries past 99 are skipped
	cmp.l	#PART_MAX_REC,d7
	bhs.w	_psg_done
;-- byte offset = idx * entrySize; 512-byte sectors -> block = base
;   + offset>>9, rem = offset & 511
	;Overflow ends the scan: later offsets can only increase.
	ifd	__68020__
	move.l	d6,d0
	mulu.l	d2,d0			;index * entrySize
	bvs.w	_psg_done		;byte offset exceeds 32 bits
	else
	;Index < 100: both 16-bit partial products fit in 32 bits.
	move.l	d6,d0
	swap	d0
	mulu.w	d2,d0			;index * entrySize high word
	cmp.l	#$ffff,d0
	bhi.w	_psg_done		;high product cannot fit its half
	swap	d0
	clr.w	d0
	move.l	d6,d1
	mulu.w	d2,d1			;index * entrySize low word
	add.l	d1,d0
	bcs.w	_psg_done		;byte offset exceeds 32 bits
	endif	;__68020__
	move.l	d0,d3
	andi.l	#$1ff,d3		;d3 = byte offset within block (kept
					;     across the callback: preserved reg)
	lsr.l	#8,d0
	lsr.l	#1,d0			;d0 = offset / 512
	add.l	d4,d0			;d0 = absolute LBA of the entry block
	bcs.w	_psg_done		;do not read a wrapped LBA
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
	bcs.s	_psg_enext		;last LBA precedes first
	addq.l	#1,d0			;d0 = last - first + 1 = block count
	bcs.s	_psg_enext		;2^32 blocks cannot fit PartRec
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
