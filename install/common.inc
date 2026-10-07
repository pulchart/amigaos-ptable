; copy copy-src into copy-dest; ask before replacing a newer installed file
(procedure P_COPY
  (set copy-file (tackon copy-dest (fileonly copy-src)))
  (set copy-go 1)
  (if (exists copy-file)
    (if (> (getversion copy-file) (getversion copy-src))
      (set copy-go
        (askbool
          (prompt (cat copy-file " is newer than the one in this archive. Replace it?"))
          (help @askbool-help)
          (default 0)))))
  (if copy-go
    (copyfiles
      (prompt (cat "Copying " (fileonly copy-src) " to " copy-dest))
      (help @copyfiles-help)
      (source copy-src)
      (dest copy-dest))))
; fa-active 1 when the first line of fa-file matching fa-pattern is not a comment;
; Search matches anywhere in a line and getenv returns only the first line
(procedure P_FIRST_ACTIVE
  (set fa-active 0)
  (if (exists fa-file)
    (
      (run (cat "Search >ENV:instfa \"" fa-file "\" \"" fa-pattern "\" PATTERN NONUM"))
      (set fa-line (getenv "instfa"))
      (if (exists "ENV:instfa") (delete "ENV:instfa"))
      (if (<> fa-line "")
        (if (<> (substr fa-line 0 1) ";")
          (if (<> (substr fa-line 0 1) "#")
            (set fa-active 1)))))))
; an older per-package section lm-old becomes a comment
(procedure P_LMOLD
  (if (= 0 (run (cat "Search >NIL: S:User-Startup \";BEGIN " lm-old "\" QUIET")))
    (startup lm-old
      (prompt (cat "Removing the old " lm-old " section of S:User-Startup"))
      (help @startup-help)
      (command "; merged into the shared section\n"))))
; one shared LoadModule line in S:User-Startup for cfd and fat95: LoadModule
; replaces the modules of an earlier call, so all of them go into one command.
; In: lm-self ("cfd" or "fat95"), lm-on; the other package keeps its state.
(procedure P_LOADMODULE
  (set lm-cfdmods (cat "LIBS:compactflash.automount LIBS:ptable.library "
                       "DEVS:compactflash.device "))
  (set fa-file "S:User-Startup")
  (set fa-pattern "LoadModule#?compactflash.device")
  (P_FIRST_ACTIVE)
  (set lm-cfd (if (= lm-self "cfd") lm-on fa-active))
  (set fa-pattern "LoadModule#?L:fat95")
  (P_FIRST_ACTIVE)
  (set lm-fat95 (if (= lm-self "fat95") lm-on fa-active))
  (set lm-mods (cat (if lm-cfd lm-cfdmods "") (if lm-fat95 "L:fat95 " "")))
  (set lm-line
    (if (= lm-mods "")
      (cat ";LoadModule >NIL: " lm-cfdmods "L:fat95 DOWNGRADE\n")
      (cat "LoadModule >NIL: " lm-mods "DOWNGRADE\n")))
  (set lm-old "cfd")
  (P_LMOLD)
  (set lm-old "fat95")
  (P_LMOLD)
  (if (= 0 (run "Search >NIL: S:User-Startup \";BEGIN LoadModule\" QUIET"))
    (startup "LoadModule"
      (prompt "Updating the LoadModule section of S:User-Startup")
      (help @startup-help)
      (command lm-line))
    (if (<> lm-mods "")
      (
        (set fa-pattern "LoadModule")
        (P_FIRST_ACTIVE)
        (if fa-active
          (message (cat "S:User-Startup already has a LoadModule line, and two of them do not "
                        "work together. Add these modules to it by hand: " lm-mods))
          (
            (textfile (dest "T:us-section")
                      (append (cat ";BEGIN LoadModule\n" lm-line ";END LoadModule\n")))
            (if (exists "S:User-Startup")
              (run "Join T:us-section S:User-Startup AS T:us-section.new")
              (run "Copy T:us-section T:us-section.new"))
            (run "Copy T:us-section.new S:User-Startup")
            (delete "T:us-section")
            (delete "T:us-section.new")))))))
