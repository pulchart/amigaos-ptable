;===========================================================
; umul32.i - 32-bit unsigned multiply
;
; Macro UMUL32: d0 = d0 * d1 (u32), V set when the product exceeds 32 bits
; (d0 is then undefined).
; Inlines mulu.l on 68020+; calls UMul32 on 68000.
;===========================================================

UMUL32	macro				;d0 = d0 * d1 (u32), V on overflow
	ifd	__68020__
	mulu.l	d1,d0
	else
	bsr	UMul32
	endif
	endm

	ifnd	__68020__

UMul32:
	movem.l	d2-d3,-(sp)
	move.l	d0,d2
	swap	d2			;d2.w = high word of d0
	move.l	d1,d3
	swap	d3			;d3.w = high word of d1
	tst.w	d2
	beq.s	_um_alo
	tst.w	d3
	bne.s	_um_ovf			;both high words set
	mulu.w	d1,d2			;d2 = high(d0) * low(d1)
	bra.s	_um_cross
_um_alo:
	mulu.w	d0,d3			;d3 = high(d1) * low(d0)
	move.l	d3,d2
_um_cross:
	swap	d2
	tst.w	d2			;cross product above 16 bits
	bne.s	_um_ovf			;else d2 = cross product << 16
	mulu.w	d1,d0			;d0 = low(d0) * low(d1)
	add.l	d2,d0
	bcs.s	_um_ovf
	movem.l	(sp)+,d2-d3
	andi.b	#$FD,ccr		;V clear
	rts
_um_ovf:
	movem.l	(sp)+,d2-d3
	ori.b	#$02,ccr		;V set
	rts

	endif	;__68020__
