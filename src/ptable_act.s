;===========================================================
; ptable_act.s - act stage: register / mount / unmount entries
;
; The act stages consume ONLY partition.resource entries published by
; ptable_scan.s. One DeviceNode builder serves both contexts:
;
;   _actCold    cold stage (RTF_COLDSTART): AddBootNode for bootable
;               RDB entries, AddDosNode(flags=0) for the rest;
;               System-Startup starts the handlers (steps 3-8).
;   _actMount   runtime (process context): AddDosNode(ADNF_STARTPROC)
;               for new entries.
;   _actUnmount runtime teardown: ACTION_DIE + RemDosEntry + free per
;               matched entry (all, or by dostype-prefix policy).
;
; Callers hold PTR_Lock; a4 = &BootCtx (BC_DevName/BC_Unit always,
; BC_DevNameBSTR + BC_ExpBase for cold/mount, BC_DosBase for unmount),
; a5 = ExecBase.
;===========================================================

;===========================================================
; _actBuildBlob: build the DeviceNode blob for one entry.
; In : a3 = PartEntry, a4 = &BootCtx, a5 = ExecBase
; Out: d0 = blob byte address (0 = alloc failure)
; The blob layout (shared by the cold and runtime mount paths):
;   [  0..43 ] DeviceNode   [ 44..59 ] FileSysStartupMsg
;   [ 60..143] DosEnvec     [144..175] dn_Name BSTR
; The FileSysEntry patch (handler binding) is applied here, BEFORE
; the caller's Add*Node (expansion's FFS auto-attach would otherwise
; silently replace a custom handler).
;===========================================================
_actBuildBlob:
	movem.l	d2-d3/a2/a6,-(sp)
	move.l	#DN_BLOB_SIZE,d0
	move.l	#MEMF_PUBLIC+MEMF_CLEAR+MEMF_REVERSE,d1
	move.l	a5,a6
	jsr	AllocMem(a6)
	tst.l	d0
	beq.w	_abb_fail
	move.l	d0,a2			;a2 = DN blob

;-- DeviceNode defaults (the FSE patch below may override)
	move.l	#-1,36(a2)		;dn_GlobVec
	move.l	#4000,20(a2)		;dn_StackSize
	moveq.l	#5,d0
	move.l	d0,24(a2)		;dn_Priority

;-- resolve Flags + Control for this entry (writes pe_MountFlags / pe_Control)
	bsr	_actResolveCfg

;-- name BSTR from the entry (publish already clamped to 31)
	lea	pe_NameB(a3),a0
	lea	DN_BSTR_OFF(a2),a1
	moveq.l	#0,d3
	move.b	(a0),d3
	addq.l	#1,d3			;length byte + chars
_abb_ncp:
	move.b	(a0)+,(a1)+
	subq.l	#1,d3
	bne.s	_abb_ncp
	lea	DN_BSTR_OFF(a2),a1
	move.l	a1,d0
	lsr.l	#2,d0
	move.l	d0,40(a2)		;dn_Name = BPTR

;-- uniquify against eb_MountList (_bootDedupName wants a5 = DN blob)
	move.l	a5,-(sp)
	move.l	a2,a5
	bsr	_bootDedupName
	move.l	(sp)+,a5

;-- if _bootDedupName uniquified the name (it differs from the scan name in
;   pe_NameB), record the actual registered name as pe_MountName so lsptres
;   shows scanname>realname (same convention as a static RegisterPartition).
;   pe_NameB is left as the scan name.
	move.l	a2,-(sp)		;save DN blob ptr (a2 reused by the compare)
	lea	DN_BSTR_OFF(a2),a0	;a0 = actual (blob) name BSTR (arg A)
	lea	pe_NameB(a3),a2		;a2 = scan name BSTR (arg B)
	bsr	_bootBStrEqualCI	;Z = equal; preserves a0/a2/d1-d3
	move.l	(sp)+,a2		;restore DN blob ptr
	beq.s	_abb_nomname		;name unchanged -> no pe_MountName
	lea	DN_BSTR_OFF(a2),a0	;src = actual name BSTR
	lea	pe_MountName(a3),a1	;dst = pe_MountName
	moveq.l	#0,d0
	move.b	(a0),d0			;length byte
	addq.l	#1,d0			;+ chars
_abb_nwb:
	move.b	(a0)+,(a1)+
	subq.l	#1,d0
	bne.s	_abb_nwb
_abb_nomname:

;-- FileSysStartupMsg
	lea	DN_FSSM_OFF(a2),a1
	move.l	a1,d0
	lsr.l	#2,d0
	move.l	d0,28(a2)		;dn_Startup = BPTR(FSSM)
	move.l	BC_Unit(a4),(a1)	;fssm_Unit
	move.l	BC_DevNameBSTR(a4),4(a1) ;fssm_Device
	lea	DN_ENVEC_OFF(a2),a0
	move.l	a0,d0
	lsr.l	#2,d0
	move.l	d0,8(a1)		;fssm_Environ = BPTR(envec)
	move.l	pe_MountFlags(a3),12(a1)	;fssm_Flags (resolved; 0 on cold path)

;-- copy the entry's envec (TableSize + 1 longs)
	lea	pe_Envec(a3),a1
	move.l	(a1),d3			;TableSize
	addq.l	#1,d3
_abb_ecp:
	move.l	(a1)+,(a0)+
	subq.l	#1,d3
	bne.s	_abb_ecp

;-- CONTROL -> de_Control (only if the resolved pe_Control is non-empty):
;   copy the BSTR into the blob, point de_Control at it, raise TableSize >= 18
	lea	pe_Control(a3),a0
	moveq.l	#0,d0
	move.b	(a0),d0			;control length
	beq.s	_abb_noctrl
	lea	pe_Control(a3),a0	;src BSTR (len + chars)
	lea	DN_CTRL_OFF(a2),a1	;dst in blob
	addq.l	#1,d0			;len byte + chars
_abb_ccp:
	move.b	(a0)+,(a1)+
	subq.l	#1,d0
	bne.s	_abb_ccp
	lea	DN_CTRL_OFF(a2),a1
	move.l	a1,d0
	lsr.l	#2,d0			;BPTR
	lea	DN_ENVEC_OFF(a2),a1	;envec base
	move.l	d0,72(a1)		;de_Control (longword index 18)
	cmp.l	#18,(a1)		;de_TableSize
	bcc.s	_abb_noctrl
	move.l	#18,(a1)
_abb_noctrl:

;-- bind the handler from FileSystem.resource (before Add*Node): exact dostype
;   first; else, for the FAT family only, the shared FAT handler matched by
;   family (high 3 bytes, any low byte) - one handler serves every FAT
;   partition. Other filesystems must match exactly. No match -> do not mount.
	move.l	a5,a6			;ExecBase for _bootFindFSEntry
	move.l	pe_DosType(a3),d0
	bsr	_bootFindFSEntry
	tst.l	d0
	bne.s	_abb_fse
	move.l	pe_DosType(a3),d0
	and.l	#$FFFFFF00,d0
	cmp.l	#$46415400,d0		;FAT family only (shared fat95 seglist)
	bne.s	_abb_nofs
	move.l	pe_DosType(a3),d0
	bsr	_bootFindFSFamily
	tst.l	d0
	bne.s	_abb_fse
_abb_nofs:
;-- no handler for this dostype: free the blob and fail so the caller leaves
;   the entry present-only (P---) instead of marking a handler-less node MOUNTED
	move.l	a2,a1
	move.l	#DN_BLOB_SIZE,d0
	move.l	a5,a6
	jsr	FreeMem(a6)
	moveq.l	#0,d0
	movem.l	(sp)+,d2-d3/a2/a6
	rts
_abb_fse:
	move.l	d0,a1
	move.l	a2,a0
	bsr	_bootPatchDNfromFSE
	move.l	a2,d0
	movem.l	(sp)+,d2-d3/a2/a6
	rts
_abb_fail:
	moveq.l	#0,d0
	movem.l	(sp)+,d2-d3/a2/a6
	rts

;===========================================================
; _actResolveCfg: resolve Flags + Control for one entry from BC_MountCfg.
; In : a3 = entry, a4 = &BootCtx ; writes pe_MountFlags + pe_Control(a3).
; cfg 0 -> flags 0, no control. Per-dostype override (matched on
; pe_DosType & $FFFFFF00) replaces the global Flags/Control when present.
;===========================================================
_actResolveCfg:
	movem.l	d0-d4/a0-a1,-(sp)
	moveq.l	#0,d2			;d2 = flags
	moveq.l	#0,d3			;d3 = control C-string (0 = none)
	move.l	BC_MountCfg(a4),d4
	beq.s	_arc_store		;cold / no cfg -> defaults
	move.l	d4,a0
	move.l	mc_Flags(a0),d2
	move.l	mc_Control(a0),d3
	move.l	mc_Overrides(a0),d4	;override table (0 = none)
	beq.s	_arc_store
	move.l	pe_DosType(a3),d0
	and.l	#$FFFFFF00,d0		;d0 = dostype prefix
	move.l	d4,a0			;a0 = override row
_arc_ov:
	move.l	ovr_Prefix(a0),d1
	beq.s	_arc_store		;end of table -> globals
	cmp.l	d1,d0
	bne.s	_arc_ovnext
	tst.b	ovr_HasFlags(a0)
	beq.s	_arc_ovctl
	move.l	ovr_Flags(a0),d2	;override flags
_arc_ovctl:
	move.l	ovr_Control(a0),d1
	beq.s	_arc_store		;no control override -> keep global
	move.l	d1,d3
	bra.s	_arc_store
_arc_ovnext:
	lea	ovr_Sizeof(a0),a0
	bra.s	_arc_ov
_arc_store:
	move.l	d2,pe_MountFlags(a3)
	lea	pe_Control(a3),a1
	tst.l	d3
	beq.s	_arc_empty
	move.l	d3,a0			;a0 = control C-string
	moveq.l	#0,d0			;d0 = length
	addq.l	#1,a1			;a1 = dest chars (past length byte)
_arc_ccp:
	move.b	(a0)+,d1
	beq.s	_arc_clen		;NUL -> done
	cmp.b	#31,d0
	bhs.s	_arc_clen		;clamp at 31
	move.b	d1,(a1)+
	addq.b	#1,d0
	bra.s	_arc_ccp
_arc_clen:
	lea	pe_Control(a3),a1
	move.b	d0,(a1)			;length byte
	bra.s	_arc_done
_arc_empty:
	clr.b	(a1)			;empty control
_arc_done:
	movem.l	(sp)+,d0-d4/a0-a1
	rts

;===========================================================
; _actMatch: does this entry belong to BC_DevName/BC_Unit?
; In : a3 = entry, a4 = &BootCtx ; Out: d0 = 1/0
;===========================================================
_actMatch:
	move.l	BC_Unit(a4),d0
	cmp.l	pe_Unit(a3),d0
	bne.s	_amt_no
	movem.l	a0-a1,-(sp)
	move.l	pe_Device(a3),a0
	move.l	BC_DevName(a4),a1
	bsr	_psStrEq
	movem.l	(sp)+,a0-a1
	rts				;d0 already 1/0
_amt_no:
	moveq.l	#0,d0
	rts

;===========================================================
; _actCold: cold-register every mountable entry for this unit.
; In : a4 = &BootCtx (BC_ExpBase, BC_ConfigDev, BC_DevNameBSTR set),
;      a5 = ExecBase; PTR_Lock held
; Out: d0 = entries registered; BC_HaveNodes/BC_PartCount updated
;===========================================================
_actCold:
	movem.l	d2-d7/a2-a3/a6,-(sp)
	moveq.l	#0,d7			;d7 = registered count
	bsr	_partGetResource
	tst.l	d0
	beq.w	_acd_out
	move.l	d0,a2
	lea	PTR_PartList(a2),a2
	move.l	(a2),a3
_acd_walk:
	move.l	(a3),d4			;succ
	tst.l	d4
	beq.w	_acd_out
	bsr	_actMatch
	tst.l	d0
	beq.w	_acd_next
	move.b	pe_Flags(a3),d3
	btst	#PEB_NOMOUNT,d3
	bne.w	_acd_skipdbg
	btst	#PEB_MOUNTED,d3
	bne.w	_acd_next

	bsr	_actBuildBlob
	tst.l	d0
	beq.w	_acd_next
	move.l	d0,d6			;d6 = DN blob

;-- bootable RDB -> AddBootNode (boot menu + strap); else AddDosNode
	move.l	BC_ExpBase(a4),a6
	cmpi.b	#PES_RDB,pe_Source(a3)
	bne.s	_acd_dos
	btst	#PEB_BOOTABLE,d3
	beq.s	_acd_dos
	ifd	DEBUG
	lea	dbg_boot_part_boot(pc),a0
	bsr	_bootDebug
	lea	pe_NameB(a3),a0
	bsr	_bootDebugBStrR
	bsr	_bootDebugPartTail
	endc
	move.l	pe_BootPri(a3),d0
	moveq.l	#0,d1			;flags=0: strap starts dos later
	move.l	d6,a0
	move.l	BC_ConfigDev(a4),a1
	jsr	AddBootNode(a6)
	bra.s	_acd_reg
_acd_dos:
	ifd	DEBUG
	lea	dbg_boot_part_dos(pc),a0
	bsr	_bootDebug
	lea	pe_NameB(a3),a0
	bsr	_bootDebugBStrR
	bsr	_bootDebugPartTail
	endc
	move.l	pe_BootPri(a3),d0
	moveq.l	#0,d1
	move.l	d6,a0
	jsr	AddDosNode(a6)
_acd_reg:
	move.l	d6,pe_DevNode(a3)
	move.l	d6,pe_BlobPtr(a3)
	move.l	#DN_BLOB_SIZE,pe_BlobSize(a3)
	bset	#PEB_MOUNTED,d3
	move.b	d3,pe_Flags(a3)
	move.b	#1,BC_HaveNodes(a4)
	addq.b	#1,BC_PartCount(a4)
	addq.l	#1,d7
	ifd	DEBUG
	bra.s	_acd_next		;skip the NOMOUNT trace below
	endc
_acd_skipdbg:
	ifd	DEBUG
	lea	dbg_boot_part_skip(pc),a0
	bsr	_bootDebug
	lea	pe_NameB(a3),a0
	bsr	_bootDebugBStrR
	lea	dbg_boot_skip_tail(pc),a0
	bsr	_bootDebug
	endc
_acd_next:
	move.l	d4,a3
	bra.w	_acd_walk
_acd_out:
	move.l	d7,d0
	movem.l	(sp)+,d2-d7/a2-a3/a6
	rts

;===========================================================
; _actMount: runtime-mount every new entry for this unit.
; In : a4 = &BootCtx (BC_ExpBase, BC_DevNameBSTR set), a5 = ExecBase;
;      PTR_Lock held; PROCESS context (ADNF_STARTPROC)
; Out: d0 = entries mounted
;===========================================================
_actMount:
	movem.l	d2-d7/a2-a3/a6,-(sp)
	moveq.l	#0,d7
	bsr	_partGetResource
	tst.l	d0
	beq.w	_amo_out
	move.l	d0,a2
	lea	PTR_PartList(a2),a2
	move.l	(a2),a3
_amo_walk:
	move.l	(a3),d4
	tst.l	d4
	beq.w	_amo_out
	bsr	_actMatch
	tst.l	d0
	beq.w	_amo_next
	move.b	pe_Flags(a3),d3
	btst	#PEB_NOMOUNT,d3
	bne.w	_amo_next
	btst	#PEB_MOUNTED,d3
	bne.w	_amo_next

;-- reuse a persistent slot node if one with this name already exists
;   (same card reinserted, or a different card reusing the CFa<i> slot): the
;   auto-detect handler re-binds the current partition itself, so we only bind
;   the entry to it, with no second AddDosNode (which would .N-suffix the name).
	lea	pe_NameB(a3),a0
	bsr	_bootFindNode		;d0 = existing DeviceNode or 0
	tst.l	d0
	beq.s	_amo_create
	move.l	d0,pe_DevNode(a3)
	bset	#PEB_MOUNTED,d3
	move.b	d3,pe_Flags(a3)
	ifd	DEBUG
	lea	dbg_pt_reuse(pc),a0
	bsr	_bootDebug
	lea	pe_NameB(a3),a0
	bsr	_bootDebugBStrR
	bsr	_bootDebugPartTail
	endc
	addq.l	#1,d7
	bra.w	_amo_next

_amo_create:
	bsr	_actBuildBlob
	tst.l	d0
	beq.w	_amo_next
	move.l	d0,d6
	move.l	BC_ExpBase(a4),a6
	moveq.l	#0,d0			;BootPri (DOS time: irrelevant)
	moveq.l	#ADNF_STARTPROC,d1
	move.l	d6,a0
	jsr	AddDosNode(a6)
	ifd	DEBUG
	lea	dbg_pt_mounted(pc),a0
	bsr	_bootDebug
	lea	pe_NameB(a3),a0
	bsr	_bootDebugBStrR
	bsr	_bootDebugPartTail
	endc
	move.l	d6,pe_DevNode(a3)
	move.l	d6,pe_BlobPtr(a3)
	move.l	#DN_BLOB_SIZE,pe_BlobSize(a3)
	bset	#PEB_MOUNTED,d3
	move.b	d3,pe_Flags(a3)
	addq.l	#1,d7
_amo_next:
	move.l	d4,a3
	bra.w	_amo_walk
_amo_out:
	move.l	d7,d0
	movem.l	(sp)+,d2-d7/a2-a3/a6
	rts

;===========================================================
; _actUnmount: retire runtime-mounted entries for this device+unit. After the
; call an entry survives only if a live handler still serves it:
;   - matched MOUNTED entry -> tear down (ACTION_DIE + RemDosEntry + free node)
;     AND free the resource entry.
;   - if BC_UnmountPrefixes is non-zero and the entry's dostype is NOT in the
;     list -> keep the handler, only mark the entry absent (---M).
;   - published-only entry (no handler) -> free the resource entry.
; In : a4 = &BootCtx (BC_DosBase may be 0, BC_UnmountPrefixes set), a5 = ExecBase;
;      PTR_Lock held; PROCESS context (packet I/O, DOS list lock)
; Out: d0 = entries torn down
;===========================================================
_actUnmount:
	movem.l	d2-d7/a2-a3/a6,-(sp)
	moveq.l	#0,d7
	bsr	_partGetResource
	tst.l	d0
	beq.w	_aum_out
	move.l	d0,a2
	lea	PTR_PartList(a2),a2
	move.l	(a2),a3
_aum_walk:
	move.l	(a3),d2			;succ (capture pre-free)
	tst.l	d2
	beq.w	_aum_out
	bsr	_actMatch
	tst.l	d0
	beq.w	_aum_next
	move.b	pe_Flags(a3),d3
	btst	#PEB_MOUNTED,d3
	beq.w	_aum_drop		;published-only (no handler) -> free entry
;-- a MOUNTED entry: prefix list decides tear-down vs keep-handler
	move.l	BC_UnmountPrefixes(a4),d0
	beq.s	_aum_teardown		;no list -> tear down + free (documented
					;API; cfd routes an empty UNMOUNT list to
					;MarkAbsent, so no shipping caller hits this)
	move.l	pe_DosType(a3),d5
	and.l	#$FFFFFF00,d5
	move.l	d0,a0
_aum_pfx:
	move.l	(a0)+,d0
	beq.s	_aum_keep		;not in list -> keep handler, mark absent
	cmp.l	d0,d5
	bne.s	_aum_pfx
_aum_teardown:
	bsr	_actTeardownEntry	;ACTION_DIE + RemDosEntry + free node + free entry
	tst.l	d0
	bne.s	_aum_td_ok		;gone -> counted
	ifd	DEBUG
	lea	dbg_pt_umnt_busy(pc),a0	;still alive -> keep handler, mark absent
	bsr	_bootDebug
	endc
	bra.s	_aum_keep
_aum_td_ok:
	addq.l	#1,d7
	bra.w	_aum_next
_aum_keep:
	bclr	#PEB_PRESENT,pe_Flags(a3)	;handler kept, marked absent (---M)
	bra.w	_aum_next
_aum_drop:
	move.l	a5,a6			;no handler -> unlink and free the entry
	jsr	Forbid(a6)
	move.l	a3,a1
	jsr	Remove(a6)
	jsr	Permit(a6)
	move.l	a3,a0
	bsr	_psFreeEntry
_aum_next:
	move.l	d2,a3
	bra.w	_aum_walk
_aum_out:
	move.l	d7,d0
	movem.l	(sp)+,d2-d7/a2-a3/a6
	rts

;===========================================================
; _actTeardownEntry: destroy one MOUNTED entry's node + handler, then
; unlink + free the PartEntry.
; ACTION_DIE + wait-for-death -> guarded RemDosEntry (under DOS write-lock;
; PFS3 removes its own DeviceNode before dying, so remove only if still
; listed) -> free DN blob -> Remove + free the entry.
; In : a3 = entry, a4 = &BootCtx, a5 = ExecBase.
; Out: d0 = 1 torn down + freed; 0 = handler still alive / no dos.library
;      -> everything kept intact (caller marks the entry absent).
; Preserves d2/d3/d5-d7/a2/a4/a5, clobbers d0-d1/d4/a0-a1/a6.
;===========================================================
_actTeardownEntry:
	move.l	pe_DevNode(a3),a0
	bsr	_partActionDie
	tst.l	d0
	bne.s	_ate_died		;handler gone -> remove node + free blob
_ate_keep:
	moveq.l	#0,d0			;still alive -> keep the mount intact
	rts
_ate_died:
	move.l	BC_DosBase(a4),d4
	beq.s	_ate_keep		;no dos.library -> cannot unlink: keep it all
	move.l	d4,a6
	move.l	#LDF_DEVICES+LDF_WRITE,d1
	jsr	LockDosList(a6)
;-- RemDosEntry only if the node is still listed: PFS3 removes its own
;   DeviceNode before replying ACTION_DIE, fat95 leaves it to us
	move.l	d2,-(sp)		;NextDosEntry wants flags in d2
	move.l	d0,d1			;walk seed from LockDosList
	moveq.l	#LDF_DEVICES,d2
_ate_scan:
	jsr	NextDosEntry(a6)
	move.l	d0,d1			;next walk cursor / RemDosEntry arg
	beq.s	_ate_unlk		;not on the list -> nothing to remove
	cmp.l	pe_DevNode(a3),d0
	bne.s	_ate_scan
	jsr	RemDosEntry(a6)		;d1 = the node
_ate_unlk:
	move.l	(sp)+,d2
	move.l	#LDF_DEVICES+LDF_WRITE,d1
	jsr	UnLockDosList(a6)
;-- drop the eb_MountList BootNode (AddBootNode/AddDosNode both link one)
;   before freeing the blob, else its bn_DeviceNode->dn_Name dangles and
;   faults the next mount's list walk. If the unlink could not run (no
;   expansion base) keep the blob: bounded leak beats a dangling pointer.
	move.l	pe_DevNode(a3),d0
	bsr	_bootUnlinkBootNode
	tst.l	d0
	beq.s	_ate_nofree		;could not check -> keep blob memory
	move.l	pe_BlobPtr(a3),d0
	beq.s	_ate_nofree
	move.l	a5,a6
	move.l	d0,a1
	move.l	pe_BlobSize(a3),d0
	jsr	FreeMem(a6)
_ate_nofree:
	ifd	DEBUG
	lea	dbg_pt_unmounted(pc),a0
	bsr	_bootDebug
	lea	pe_NameB(a3),a0
	bsr	_bootDebugBStr
	endc
;-- node + handler gone: unlink and free the PartEntry itself
	move.l	a5,a6
	jsr	Forbid(a6)
	move.l	a3,a1
	jsr	Remove(a6)
	jsr	Permit(a6)
	move.l	a3,a0
	bsr	_psFreeEntry
	moveq.l	#1,d0			;torn down + freed
	rts

;===========================================================
; _partActionDie: ACTION_DIE to a handler process, then poll for it
; to actually vanish.
; In : a0 = DeviceNode, a4 = &BootCtx, a5 = ExecBase; PROCESS context
; Out: d0 != 0 -> handler gone (dol_Task == 0) = safe to remove the node;
;      d0 == 0 -> handler still alive after the poll = keep the mount.
;
; NEVER waits on the handler: our caller holds PTR_Lock, and a dying
; handler may block on that very lock before reaching its packet loop
; (fat95 CloseDisk -> MarkAbsent did exactly that) - waiting for the
; DIE reply here would deadlock the whole DOS list. Instead the packet
; and its reply port live in an AllocMem block; the port is PA_IGNORE
; (a reply just enqueues, signals nobody), and the only death signal is
; the bounded dol_Task poll (100 ms steps, PAD_POLL_MAX tries). Both
; handlers reply before clearing dol_Task (fat95 replies immediately
; and exits from its idle loop; PFS3 replies after clearing it), so on
; death the reply is already here and the block can be freed. If the
; handler is still alive at timeout it still owns the packet: the block
; is deliberately leaked (bounded, 102 bytes) - the PA_IGNORE port
; absorbs the eventual reply without touching any task.
;
; dol_Task is the handler's MsgPort, NOT a Process pointer (the
; field name is a historical misnomer); PutMsg goes straight to it.
;===========================================================
PAD_PKT_SIZE	= MP_Sizeof+SP_SIZEOF	;reply port + StandardPacket

_partActionDie:
	movem.l	d2-d4/a2-a4/a6,-(sp)
	move.l	a5,a6
	move.l	a0,d4			;d4 = DeviceNode (survives the packet round-trip)
	move.l	a4,d2			;d2 = &BootCtx (a4 is reused as packet ptr below)
	move.l	dol_Task(a0),d0
	bne.s	_pad_have
	moveq.l	#-1,d0			;no handler started -> nothing to kill, safe
	bra.w	_pad_out
_pad_have:
	move.l	d0,a3			;a3 = handler MsgPort
	move.l	#PAD_PKT_SIZE,d0
	move.l	#MEMF_PUBLIC+MEMF_CLEAR,d1
	jsr	AllocMem(a6)
	tst.l	d0
	bne.s	_pad_gotmem
	moveq.l	#0,d0			;cannot ask -> do not tear down
	bra.w	_pad_out
_pad_gotmem:
	move.l	d0,a2			;a2 = reply MsgPort
	lea	MP_Sizeof(a2),a4	;a4 = StandardPacket
;-- reply port: PA_IGNORE, no SigBit/SigTask (block is MEMF_CLEAR)
	move.b	#NT_MSGPORT,LN_Type(a2)
	move.b	#PA_IGNORE,MP_Flags(a2)
	lea	MP_MsgList(a2),a0
	move.l	a0,(a0)
	addq.l	#4,(a0)
	clr.l	4(a0)
	move.l	a0,8(a0)
;-- packet
	lea	20(a4),a1		;a1 = DosPacket (MN_SIZE = 20)
	move.l	a1,LN_Name(a4)		;sp_Msg.ln_Name -> packet
	move.b	#NT_MESSAGE,LN_Type(a4)
	move.l	a2,MN_ReplyPort(a4)
	move.w	#SP_SIZEOF,MN_Length(a4)
	move.l	a4,dp_Link(a1)
	move.l	a2,dp_Port(a1)
	move.l	#ACTION_DIE,dp_Type(a1)
;-- send; no reply wait (see header)
	move.l	a3,a0			;handler MsgPort (dol_Task)
	move.l	a4,a1
	jsr	PutMsg(a6)
;-- poll dol_Task until the handler clears it on exit, bounded so a
;   busy or blocked handler cannot hang us
	move.l	d2,a4			;a4 = &BootCtx again (_bootDelay100ms needs it)
	moveq.l	#PAD_POLL_MAX,d3
_pad_poll:
	move.l	d4,a0
	tst.l	dol_Task(a0)		;handler unregistered itself?
	beq.s	_pad_gone
	bsr	_bootDelay100ms		;clobbers d0/d1 only
	subq.l	#1,d3
	bne.s	_pad_poll
	moveq.l	#0,d0			;still alive after ~3 s -> keep the mount
	bra.s	_pad_out		;(packet block stays: handler owns it)
_pad_gone:
;-- dead: the reply must already be in our port - drain and free.
;   Defensively leak instead of freeing if it is not (never free a
;   packet a live handler might still touch).
	move.l	a2,a0
	jsr	GetMsg(a6)
	tst.l	d0
	beq.s	_pad_noreply
	move.l	a2,a1
	move.l	#PAD_PKT_SIZE,d0
	jsr	FreeMem(a6)
_pad_noreply:
	moveq.l	#1,d0			;dol_Task == 0 -> safe to remove the node
_pad_out:
	movem.l	(sp)+,d2-d4/a2-a4/a6
	rts
