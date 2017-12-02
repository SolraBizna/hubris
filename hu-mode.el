;;; hu-mode.el --- A major mode for editing Hubris source code

;; Copyright (C) 2017 Solra Bizna

;; Author: Solra Bizna <solra@bizna.name>
;; Version: 0.0
;; Keywords: hubris, 6502, 65c02
;; URL: https://github.com/SolraBizna/hubris

;;; Commentary:

;; hu-mode.el is a not-very-bright major mode for editing code in the Hubris
;; language. Hubris is a simple programming language targeting the W65C02
;; processor.

;;; Code:

; Written with the help of: https://www.emacswiki.org/emacs/ModeTutorial

;;;###autoload
(add-to-list 'auto-mode-alist '("\\.hu\\'" . hu-mode))

(defvar hu-mode-hook nil)

(defvar hu-mode-map
  (let ((map (make-keymap)))
    (define-key map (kbd "TAB") 'self-insert-command)
    map)
  "Keymap for Hubris major mode")

(defconst hu-font-lock-keywords
  (list
   '("\\<UNSAFE\\>" .font-lock-warning-face)
   '("^[[:space:]]*#\\(?:alias\\|b\\(?:ankcount\\|egin\\|ranchflag\\(?:clear\\|\\(?:re\\)?set\\)\\|s\\)\\|c\\(?:all\\|learflag\\|ommon\\)\\|end\\(?:routine\\|common\\)\\|g\\(?:lobal\\(?:flag\\|alias\\)?\\|roup\\)\\|in\\(?:clude\\|directcallers?\\)\\|local\\(?:flag\\)?\\|param\\(?:flag\\)?\\|r\\(?:e\\(?:gion\\|setflag\\|turn\\)\\|outine\\)\\|s\\(?:etflag\\|lot\\|ublocal\\(?:flag\\)?\\)\\|unalias\\)\\>" . font-lock-builtin-face)
   '("^[[:space:]]*#\\sw+" . font-lock-warning-face)
   '("#" . font-lock-constant-face)
   '("\\<\\(?:\\$[0-9A-Fa-f]+\\|[0-9]+\\)\\>" . font-lock-constant-face)
   '("\\<\\(?:A\\(?:DC\\|ND\\|SL\\)\\|B\\(?:C[CS]\\|EQ\\|IT\\|MI\\|NE\\|PL\\|R[AK]\\|V[CS]\\|B[RS][0-7]\\)\\|C\\(?:L[CDIV]\\|MP\\|P[XY]\\)\\|DE[ACXY]\\|EOR\\|IN[ACXY]\\|J\\(?:MP\\|SR\\)\\|L\\(?:D[AXY]\\|SR\\)\\|NOP\\|ORA\\|P\\(?:H[APXY]\\|L[APXY]\\)\\|R\\(?:O[LR]\\|T[IS]\\|MB[0-7]\\)\\|S\\(?:BC\\|E[CDI]\\|T[APXYZ]\\|MB[0-7]\\)\\|T\\(?:A[XY]\\|RB\\|S[BX]\\|X[YS]\\|YA\\)\\|WAI\\)\\(?:\\.[WB]\\)?\\>" . font-lock-keyword-face)
   '("\\(?:[[:space:]]\\|^\\)*\\.\\sw+" . font-lock-keyword-face)
   '("\\<\\(?:ANY\\|BYTE\\|CLOBBER\\|ENTRY\\|GROUP\\|INTER\\(?:RUPT\\)?\\|JUMP\\|ORGA\\|P\\(?:ERSIST\\|RESERVE\\|TR\\)\\|WORD\\|[AXY]\\)\\>" . font-lock-keyword-face)
   '("^[^[:space:]#]+:" . font-lock-function-name-face)
   '("\\(?:[[:space:]]\\|^\\)\\(\\-+\\|\\++\\)" . font-lock-function-name-face))
  "Highlighting expressions for Hubris mode")

(defvar hu-mode-syntax-table
  (let ((st (make-syntax-table)))
    (modify-syntax-entry ?_ "w" st)
    (modify-syntax-entry ?; "<" st)
    (modify-syntax-entry ?\n ">" st)
    (modify-syntax-entry ?\" "\"" st)
    st)
  "Syntax table for Hubris mode")

(defun hu-mode ()
  "Major mode for editing Hubris source code"
  (interactive)
  (kill-all-local-variables)
  (use-local-map hu-mode-map)
  (set-syntax-table hu-mode-syntax-table)
  (set (make-local-variable 'font-lock-defaults) '(hu-font-lock-keywords))
  (setq major-mode 'hu-mode)
  (setq mode-name "Hubris")
  (setq tab-width 8)
  (setq indent-tabs-mode t)
  (setq tab-always-indent nil)
  (setq comment-start-skip "; *")
  (setq comment-start ";")
  (run-hooks 'hu-mode-hook))

(provide 'hu-mode)
