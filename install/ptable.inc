; ptable.library: in ptable-src, ptable-libdir, ptable-ask-cpu, ptable-cpu, ptable-ask-lsptres; out ptable-cpu, ptable-flavor
(if ptable-ask-cpu
  (set ptable-cpu
    (select
      (askchoice
        (prompt "CPU")
        (help (cat "Selects the build of every library and device this installer copies.\n\n" "68000: A500, A600, A2000.\n\n68020: 68020 or higher, A1200, A3000, A4000, " "Apollo 68080."))
        (choices "68000/68010" "68020 or higher")
        (default (if (or (= (database "cpu") "68000") (= (database "cpu") "68010")) 0 1)))
      "68000" "68020")))
(set ptable-flavor "small")
(if (= @user-level 2)
  (set ptable-flavor
    (select
      (askchoice
        (prompt "Variant of every library and device this installer copies")
        (help (cat "small: for normal use, when you need no serial messages or "
                   "troubleshooting.\n\n"
                   "full: writes debug messages to the serial port, for troubleshooting.\n\n"
                   "Outside Expert mode the small variant is installed."))
        (choices "small: normal use" "full: serial debug messages, troubleshooting")
        (default 0))
      "small" "full")))
(set copy-src (cat ptable-src ptable-flavor "/" ptable-cpu ptable-libdir "ptable.library"))
(set copy-dest "LIBS:")
(P_COPY)
(if ptable-ask-lsptres
  (if
    (askbool
      (prompt "Copy lsptres to C:?")
      (help "lsptres lists the partitions in partition.resource.")
      (default 1))
    (copyfiles (source "c/lsptres") (dest "C:"))))
