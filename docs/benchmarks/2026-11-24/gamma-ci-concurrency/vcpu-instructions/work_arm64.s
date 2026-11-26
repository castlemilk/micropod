#include "textflag.h"

// Each nonempty loop iteration executes 16 adds, one subtract and one branch.
TEXT ·burn(SB),NOSPLIT,$0-16
	MOVD iterations+0(FP), R0
	MOVD ZR, R1
loop:
	ADD $1, R1
	ADD $1, R1
	ADD $1, R1
	ADD $1, R1
	ADD $1, R1
	ADD $1, R1
	ADD $1, R1
	ADD $1, R1
	ADD $1, R1
	ADD $1, R1
	ADD $1, R1
	ADD $1, R1
	ADD $1, R1
	ADD $1, R1
	ADD $1, R1
	ADD $1, R1
	SUBS $1, R0
	BNE loop
	MOVD R1, ret+8(FP)
	RET

