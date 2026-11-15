#!/usr/bin/env python3
"""Mock block device for the scan tests: serves DoIO from a sparse image.

The backing store is a dict {native block number: bytes}; absent blocks read
as zeros. Commands follow the NDK (devices/trackdisk.h, scsidisk.h,
newstyle.h); errors are the exec/errors.h and trackdisk.h codes.
"""

CMD_READ, TD_CHANGESTATE, TD_GETGEOMETRY, TD_READ64 = 2, 14, 22, 24
HD_SCSICMD, NSCMD_TD_READ64 = 28, 0xC000
IOERR_NOCMD, IOERR_BADLENGTH, IOERR_BADADDRESS = -3, -4, -5
TDERR_NOTSPECIFIED, TDERR_DISKCHANGED = 20, 29
DG_SIZEOF = 32

# Command sets of the device kinds the tests model.
PROFILES = {
    'cfd': {CMD_READ, TD_CHANGESTATE, TD_GETGEOMETRY, TD_READ64, HD_SCSICMD,
            NSCMD_TD_READ64},
    'scsi_v40': {CMD_READ, TD_CHANGESTATE, TD_GETGEOMETRY, HD_SCSICMD},
    'carddisk': {CMD_READ, TD_CHANGESTATE, TD_GETGEOMETRY},
    'no_changestate': {CMD_READ, TD_GETGEOMETRY, TD_READ64, NSCMD_TD_READ64},
}


class Disk:
    """One medium. blocks: {lba: bytes}; bs: native block size; total: blocks.

    inject: {(cmd, lba): error} fails a read of that native block with that
    command; (cmd, None) fails every read with it. nth_ok: {cmd: n} lets the
    first n reads with cmd fail with TDERR_NOTSPECIFIED, later ones succeed.
    geometry: None = report bs/total; 'error' = fail TD_GETGEOMETRY;
    an int = report that SectorSize.
    """

    def __init__(self, blocks, bs=512, total=None, profile='cfd', inject=None,
                 nth_fail=None, geometry=None, present=True):
        self.blocks, self.bs = dict(blocks), bs
        self.total = total if total is not None else (max(self.blocks, default=0) + 64)
        self.cmds = PROFILES[profile]
        self.inject = dict(inject or {})
        self.nth_fail = dict(nth_fail or {})
        self.geometry = geometry
        self.present = present
        self.log = []

    def block(self, lba):
        return self.blocks.get(lba, b'').ljust(self.bs, b'\0')[:self.bs]

    def read(self, cmd, offset, length):
        """Byte-addressed read; returns (error, bytes)."""
        if self.nth_fail.get(cmd, 0) > 0:
            self.nth_fail[cmd] -= 1
            return TDERR_NOTSPECIFIED, b''
        if offset % self.bs:
            return IOERR_BADADDRESS, b''
        if length % self.bs or length == 0:
            return IOERR_BADLENGTH, b''
        first = offset // self.bs
        for lba in range(first, first + length // self.bs):
            err = self.inject.get((cmd, lba), self.inject.get((cmd, None)))
            if err:
                return err, b''
        return 0, b''.join(self.block(first + i) for i in range(length // self.bs))

    def scsi_reads(self):
        """(lba, blocks, scsi_Length) of every HD_SCSICMD read in the log."""
        return [e[1:] for e in self.log if e[0] == 'scsi']
