; parts.i - PartRec output record + walker entry points
;
; Shared between parts.s (the walker) and ptable_partres.s (the
; partition.resource publisher). cfd-internal: the MBR/GPT parse
; logic lives in exactly one binary (ptable.library); fat95 reaches
; it at runtime via the ScanPartitions LVO, not by including this.

	ifnd	_PARTS_I_
_PARTS_I_	equ	1

;--- PartRec: one record per accepted partition --------------
PR_StartLBA	= 0		;u32 absolute LBA (512-byte sectors)
PR_BlockCount	= 4		;u32 sector count
PR_DosType	= 8		;u32 DOS type for the DeviceNode envec
PR_PartIndex	= 12		;u8  table slot index (MBR 0..3, GPT entry #)
PR_Flags	= 13		;u8  see PRFB_* below
PR_Sizeof	= 16		;(pad to longword)

;-- PR_Flags bit numbers (btst/bset)
PRFB_PRESENT	= 0		;record valid
PRFB_GPT	= 1		;came from a GPT entry (else MBR)
PRFB_BOOTABLE	= 2		;MBR status byte $80

;-- caller output buffer holds up to this many records
PART_MAX_REC	= 8

;-- DOSTYPE_FAT lives in ptable_pub.i (public ABI), included first by
;   every consumer of this file.

	endif	;_PARTS_I_
