; ptable.library - static ConfigDev, DiagArea and BootPoint
;
; AddBootNode gets s_boot_configdev for a bootable RDB partition. Strap
; boots it through er_Type (ERTF_DIAGVALID), er_Reserved0c (the DiagArea)
; and DAC_CONFIGTIME in da_Config, calling da_BootPoint in place. The
; ConfigDev is not registered with AddConfigDev.

DAC_CONFIGTIME	= $10

	cnop	0,4
s_boot_configdev:
	ds.b	CD_ER_TYPE		;cd_Node, cd_Flags, cd_Pad: unused
	dc.b	ERTF_DIAGVALID		;cd_Rom.er_Type
	ds.b	CD_ER_RESERVED0C-CD_ER_TYPE-1
	dc.l	s_rdb_diag_rom		;cd_Rom.er_Reserved0c: the DiagArea
	ds.b	CD_SIZEOF-CD_ER_RESERVED0C-4

	cnop	0,2
s_rdb_diag_rom:
	dc.b	DAC_CONFIGTIME		;da_Config (bit 4 required)
	dc.b	0			;da_Flags
	dc.w	0			;da_Size: nothing is copied
	dc.w	0			;da_DiagPoint: none
	dc.w	(s_rdb_bootpoint-s_rdb_diag_rom) ;da_BootPoint offset
s_rdb_bootpoint:
	;-- a6 = ExecBase (passed by Kickstart strap); a2 = BootNode (passed but unused here)
	lea	s_rdb_dosname(pc),a1
	jsr	FindResident(a6)
	tst.l	d0
	beq.s	_srbp_end
	movea.l	d0,a0
	movea.l	RT_INIT(a0),a0		;dos.library Init vector
	jsr	(a0)			;DOS starts as tasks
_srbp_end:
	rts
s_rdb_dosname:
	dc.b	"dos.library",0
	even
