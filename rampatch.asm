
// 1541 ROM patch for drives with RAM expanded into $8000-$9FFF
//      and additional ROM mapped into $A000-$BFFF
//      (32K ROM with lowest 8K not available)
// by Maciej 'YTM/Elysium' Witkowiak <ytm@elysium.pl>, V1.0

// Configuration

// RAM expansion base address, we need 8K ($2000) area, by default $8000-$9FFF
// XXX mapped to $6000 for tests in VICE
.const RAMEXP = $6000 // 8K of expanded RAM

// which ROM to patch?
// uncomment one of the definitions below or pass them to KickAss as a command line option, e.g. -define ROM1571

// 1541-II
//#define ROM1541II

// JiffyDOS for 1541-II
//#define ROMJIFFY1541II

// SpeedDOS Plus 2.7 (35 tracks)
//#define ROMSPEEDDOS35

// SpeedDOS Plus+ 2.7 (40 tracks)
#define ROMSPEEDDOS40

// INFO
// - read whole track at once and cache
// - decode headers to get the order of sectors
// - (TODO) 1541: keep GCR data, decode on demand, use procedure and lookup tables from 1571 for that
//		Coded LFT GCR decoding routine, but it turns out to be almost the same as 1571 ROM (just using 0.5K of lookups) between 98d9 and 9964.
//		My code uses LAX only, takes 224 cycles; 1571: 189; 1541: 297
//		After page aligment and LAX/SAX/SBX it's down to 206 - 31% faster
//		But 1571 lookups are 37% faster and with extra 8K I will have ROM space for that. Can THAT be improved with LAX/SAX/SBX?
// - needs only one disk revolution (20ms with 300rpm) to read whole track
// - sector GCR decoding errors are reported normally
// - header GCR decoding errors are not reported - but if sector is not found we fall back on ROM routine which should report it during next disk revolution
// - same patch for both variations: stock ROM / JiffyDOS

// Excellent resources:
// http://www.unusedino.de/ec64/technical/formats/g64.html - 10 header GCR bytes? but DOS reads only 8 http://unusedino.de/ec64/technical/aay/c1541/ro41f3b1.htm
// http://unusedino.de/ec64/technical/aay/c1541
//	- note: 1581 disassembly contains references to 1571 ROM
// https://spiro.trikaliotis.net/cbmrom
// decode 1541 sector data from GCR on the fly as in https://www.linusakesson.net/programming/gcr-decoding/index.php ?
//  - not possible: it's faster to decode using 1571 ROM lookups
//    it would be faster for reading single sectors, but we can't cache whole track - there is no time between sectors to move data outside of stack

/*

1541 ROMRAM
- ? GCR on the fly for JiffyDOS / track cache for stock / fast GCR decode from 1571 (f497 / f4ed) for both?
- **ALWAYS** faster because cycles wasted for waitning on head data are used for GCR decoding - saving 19000cycles every time
- just needs extra ROM for tables and prep code, would work even with stock RAM; with expanded RAM no problem at all (store stack contents somewhere)
	- prep: save stack somewhere ($0200 buffers or extra RAM)
	- copy code from ROM to RAM somewhere
	- wait for sector header
	- run reading in ram
	- copy data from stack to target buffer
	- restore zp/stack
- separate routine to decode one-shot 5 bytes from sector header (put on stack and retrieve)
- patch $FF10 to *not* store $FF into $1803 (it's 00 - input on reset)


if the first byte of data is not $55, I give up after 3 tries and report error 04 for that sector and move on. also, if parity fails, give up after 3 tries and report error 05. This is because my project is a disk utility and not a loader :) I cannot "hang" trying forever.

4) save/restore a portion of ZP before/after reading all the sectors I wanted, so I can return to KERNAL when done. Returning to KERNAL is important for my utility project. I am using $86-$E5 for the ZP code and only save/restore $99-$B4 -- the rest is just zero'd out.
*/

// ???
// decode one full header (1st one) and compare ID with that from $F514 while updating $16/17/18/19 too?
// could report at least ID mismatch (A=$02 + jump into f969)

.const HEADER = $16
.const HDRPNT = $32
.const STAB = $24
.const BUFPNT = $30 // (2)
.const DBID = $47

// 1571 
.const CHKSUM = $3A // (1)
.const BTAB = $52 // (4)

// 1541 ROM locations (1571 in 1541 mode)
.const LC1D1 = $C1D1 // find drive number, instruction patched at $D005
.const LF556 = $F556 // wait for sync, set Y to 0
//.const LF497 = $F497 // decode 8 GCR bytes from $24 into header structure at $16-$1A (track at $18, sector at $19)
.const LF4ED = $F4ED // part of read sector procedure right after GCR sector data is read - decode GCR from BUFPNT+$01BA:FF into BUFPNT
.const LF4F0 = $F4F0 // part of read sector procedure right after GCR sector data is decoded, compare checksum
.const LF50A = $F50A // wait for header and then for sync (F556), patched instruction at $F4D1
.const LF4D4 = $F4D4 // next instruction after patch at $F4D1

// note: if these zero-page location would cause compatibility issues, they can be moved to RAMBUF page, just making code a bit larger
//       the only exceptions are pointers bufpage/bufrest but these *may* be moved to workarea at BTAB ($52)
// DOS unused zp
.const bufpage = $14					// (2) 1541/71 pointer to page GCR data, increase by $0100
.const bufrest = $2c					// (2) 1541 pointer to remainder GCR data, increase by bufrestsize; written to by GCR decoding routine at F6D0 but on 1541 that's after bufpage/bufrest was already used, doesn't appear in patched 1571 at all
.const hdroffs = $1b					// (1) 1541/71 offset to header GCR data at RE_cached_headers during data read and header decoding
.const counter = $1d					// (1) 1541/71 counter of read sectors, saved in RE_max_sector (alternatively use $4B DOS attempt counter for header find); written to by powerup routine at $EBBA (write protect drive 1), but that's ok
.const hdroffsold = $46					// (1) 1541/71 temp storage needed to compare current header with 1st read header; written to and decremented, but only after load in $917D / $918D (after jump to L970A)

// sizes
.const hdrsize = 8						// header size in GCR (8 GCR bytes become 5 header bytes)
.const maxsector = 22					// rather 21 but we have space
.const bufrestsize = $48				// size of GCR data over page size, it's $46 really, but it's rounded up

// actual area used: $8000-7BFF (track 1, 21 sectors)
.const RAMBUF = RAMEXP+$1E00 // last page for various stuff
.const RAMEXP_REST = RAMEXP+(maxsector*$0100)	// this is where remainder GCR data starts, make sure that it doesn't overlap RAMBUF (with sector headers)
.const RE_cached_track = RAMBUF+$ff
.const RE_max_sector = RAMBUF+$fe
.const RE_lastmode = RAMBUF+$fd
.const RE_decoded_headers = RAMBUF // can be the same as RE_cached_headers, separated for debug only
.const RE_cached_headers = RAMBUF+$0100
.const RE_cached_checksums = RAMBUF-$0100 // 1571 only

/////////////////////////////////////

#if !ROM1541II && !ROMJIFFY1541II && !ROMSPEEDDOS35 && !ROMSPEEDDOS40
.error "You have to choose ROM to patch"
#endif

#if ROM1541II
.print "Assembling stock 1541-II ROM 251968-03"
.segmentdef Combined  [outBin="dos1541ii-251968-03-patched.bin", segments="Base,Patch1,Patch3,Patch4,Patch5,Patch7,Patch8,Patch9,Patch10,Patch11,Patch12,MainPatch", allowOverlap]
.segment Base [start = $8000, max=$ffff]
	.var data = LoadBinary("rom/dos1541ii-251968-03.bin")
	.fill $4000, $ff
	.fill data.getSize(), data.get(i)
#endif

#if ROMJIFFY1541II
.print "Assembling JiffyROM 1541-II"
.segmentdef Combined  [outBin="dos1541ii-251968-03-patched.bin", segments="Base,Patch1,Patch3,Patch4,Patch5,Patch7,Patch8,Patch9,Patch10,Patch11,Patch12,MainPatch", allowOverlap]
.segment Base [start = $C000, max=$ffff]
	.var data = LoadBinary("rom/dos1541ii-251968-03.bin")
	.fill $4000, $ff
	.fill data.getSize(), data.get(i)
#endif

#if ROMSPEEDDOS35
.print "Assembling SpeedDOS Plus 2.7 35 tracks ROM"
.print "Use with parallel cable and C64-SpeedDOS-Plus-patched.bin"
.segmentdef Combined  [outBin="1541-II-SpeedDOS-35-patched.bin", segments="Base,Patch1,Patch3,Patch4,Patch5,Patch7,Patch8,Patch9,Patch10,Patch11,MainPatch", allowOverlap]
.segment Base [start = $8000, max=$ffff]
	.var data = LoadBinary("rom/1541-II-SpeedDOS-35.rom")
	.fill $4000, $ff
	.fill data.getSize(), data.get(i)

.segmentdef Combined2 [outBin="C64-SpeedDOS-Plus-patched.bin", segments="KernalBase,SpeedDOSPatch1", allowOverlap]
.segment KernalBase [start = $e000, max=$ffff]
	.var data2 = LoadBinary("rom/C64-SpeedDOS-Plus.rom")
	.fill data2.getSize(), data2.get(i)

#endif

#if ROMSPEEDDOS40
.print "Assembling SpeedDOS Plus+ 2.7 40 tracks ROM"
.print "Use with parallel cable and C64-SpeedDOS-Plus+-patched.bin"
.segmentdef Combined  [outBin="1541-II-SpeedDOS-40-patched.bin", segments="Base,Patch1,Patch3,Patch4,Patch5,Patch7,Patch8,Patch9,Patch10,Patch11,MainPatch", allowOverlap]
.segment Base [start = $8000, max=$ffff]
	.var data = LoadBinary("rom/1541-II-SpeedDOS-40.rom")
	.fill $4000, $ff
	.fill data.getSize(), data.get(i)

.segmentdef Combined2 [outBin="C64-SpeedDOS-Plus+-patched.bin", segments="KernalBase,SpeedDOSPatch1", allowOverlap]
.segment KernalBase [start = $e000, max=$ffff]
	.var data2 = LoadBinary("rom/C64-SpeedDOS-Plus+.rom")
	.fill data2.getSize(), data2.get(i)

#endif


/////////////////////////////////////

#if ROMSPEEDDOS35 || ROMSPEEDDOS40

.segment SpeedDOSPatch1 [min=$F74A, max=$F791]
		.pc = $F74A "Patch LOAD to just run M-E $A000"
		lda #$45		// M-'E'
		jsr $f7e5
		lda #<SpeedDOSRun
		jsr $eddd
		lda #>SpeedDOSRun
		jsr $eddd
		jmp $f791		// unlisten+wait for data XXX could patch it also to use loadaddress

#endif

/////////////////////////////////////

.segment Patch1 []
		.pc = $F4D1 "Patch 1541 sector read"
		jmp ReadSector

.segment Patch2 []
		.pc = $F497 "Patch 1541 header decode"
		jmp LF497

.segment Patch3 []
		.pc = $C649 "Patch disk change"
		jsr ResetCache

.segment Patch4 []
		.pc = $EAE4 "Patch ROM checksum" // different than on 1571
		nop
		nop
		nop
		nop
		nop
		nop

.segment Patch5 []
		.pc = $F2C0 "Patch 1541 IRQ routine for disk controller"
		jsr InvalidateCacheForJob

.segment Patch7 []
		.pc = $D005 "Patch 'I' command"
		jsr InitializeAndResetCache

.segment Patch8 []
		.pc = $F497 "Patch sector header decoding"
		jmp LF497

.segment Patch9 []
		.pc = $F4ED "Patch call to decode sector buffer from GCR after sector read"
		jsr LF8E0

.segment Patch10 []
		.pc = $F8E0 "Patch GCR sector decoding to use faster routine from 1571"
		jmp LF8E0

.segment Patch11 []
		.pc = $F7E6 "Patch 5 GCR to 4 BIN decoding"
		jmp L98D9

.segment Patch12 []
		.pc = $FF10 "Patch to not set VIA#1 port A to output (safer for parallel cable)"
		nop	// was STX $1803
		nop
		nop

/////////////////////////////////////

.segment MainPatch [min=$A000,max=$BFFF]

		// $E31C-$E4FB area used for REL files only (hopefully)
		//.pc = $E31C "Patch"
		//rts

		.pc = $A000

#if ROMSPEEDDOS35 || ROMSPEEDDOS40
SpeedDOSRun:
		jmp SpeedDOSLoader		// SpeedDOS loader at a fixed address for C64 Kernal side
#endif

/////////////////////////////////////

InvalidateCacheForJob: {
		tya						// enters with Y as job number (5,4,3,2,1,0), we can change A,X but not Y
		tax
		lda $00,x				// job?
		bpl return				// no job
		cmp #$D0				// execute code?
		beq return				// yes, exec doesn't seek to track
		cmp #$90				// write sector?
		beq resetcache			// yes, always invalidate cache
		tya						// get track
		asl						// *2
		tax
		lda $06,x				// check track parameter for job
		cmp RE_cached_track		// is it cached already?
		beq return				// yes, there will be no track change
resetcache:
		jsr ResetOnlyCache		// invalidate cache
return:
		lda $00,y				// instruction from patched $F2C0 and $92CA, must change CPU flags
		rts
}

/////////////////////////////////////

InitializeAndResetCache:
		jsr ResetOnlyCache
		jmp LC1D1				// instruction from patched $D005

/////////////////////////////////////

ResetCache:						// enters with A=$FF
		sta $0298				// instruction from patched $C649, set error flag
ResetOnlyCache:
		lda #$ff
		sta RE_cached_track		// set invalid values
		sta RE_max_sector
		rts

/////////////////////////////////////

ReadSector:
// patch $F4D1 to jump in here, required sector number is on (HDRPNT)+1, required track in (HDRPNT), data goes into buffer at (BUFPNT)
		ldy #0
		lda (HDRPNT),y			// is cached track the same as required track?
		cmp RE_cached_track
		beq ReadCache
		jmp ReadTrack			// no - read the track

ReadCache:
		sta $18					// track that we want to read, LF510 (read sector header puts it here for encoding, but some fastloaders might need it (SpeedDOS))
		iny						// yes, track is cached, just put GCR data back and jump into ROM
		lda (HDRPNT),y			// needed sector number
		sta hdroffs				// keep it here
		sta $19					// sector number that we want to read, LF510 (read sector header puts it here for encoding, but some fastloaders might need it (SpeedDOS))
		// setup pointers
		lda #>RAMEXP			// pages - first 256 bytes
		sta bufpage+1
		lda #>RAMEXP_REST		// remainders - following bytes until end of sector ($46 bytes)
		sta bufrest+1
		lda #0
		sta bufpage
		sta bufrest
		// find sector
		ldx #0
!loop:	lda RE_cached_headers,x
		cmp hdroffs
		beq !found+
		// no, next one
		inc bufpage+1
		lda bufrest
		clc
		adc #bufrestsize
		sta bufrest
		bcc !+
		inc bufrest+1
!:		inx
		cpx RE_max_sector
		bne !loop-
		// not found? fall back on ROM and try to read it again
		jsr LF50A				// replaced instruction
		jmp LF4D4				// next instruction

!found:
		// decode GCR sector data
		{
		lda #$00		// customized LF8E0 / 9965
		sta $34
		sta $2E
		sta $36
		lda BUFPNT+1	// write to here
		sta $2F
		jsr Decode5GCR	// customized 98D9 / F7E6
		lda $52
		sta $38
		ldy $36
		lda $53
		sta ($2E),Y
		iny
		lda $54
		sta ($2E),Y
		iny
		lda $55
		sta ($2E),Y
		iny
L9991:	sty $36
		jsr Decode5GCR
		ldy $36
		lda $52
		sta ($2E),Y
		iny
		beq L99B0
		lda $53
		sta ($2E),Y
		iny
		lda $54
		sta ($2E),Y
		iny
		lda $55
		sta ($2E),Y
		iny
		bne L9991
L99B0:	lda $53			// not in 1571 code
		sta $3A			// not in 1571 code
		}

		jmp LF4F0		// we have data as if it came from the disk, continue in ROM: return 'ok' (or sector checksum read error)

/////////////////////////////////////

ReadTrack:
		sta RE_cached_track		// this will be our new track for caching

		lda #>RAMEXP			// pages - first 256 bytes
		sta bufpage+1
		lda #>RAMEXP_REST		// remainders - following bytes until end of sector ($46 but we add $80 each time)
		sta bufrest+1
		lda #0
		sta bufpage
		sta bufrest
		sta hdroffs				// 8-byte counter for sector headers at RAMBUF
		sta counter				// data block counter

		// end loop when header we just read is the same as 1st read counter (full disk revolution) or block counter is 23
ReadHeader:
		jsr	LF556			// ; wait for SYNC, Y=0
		ldx hdroffs
		stx hdroffsold
		//ldy #0			// F556 sets Y to 0
!:		bvc !-
		clv
		lda $1c01
		cmp #$52			// is that a header?
		bne ReadHeader		// no, wait until next SYNC
		sta RE_cached_headers,x
		inx
		iny					// yes, read remaining 8 bytes (or 10?)
!:		bvc !-
		clv
		lda $1c01
		sta RE_cached_headers,x
		inx
		iny
		cpy #hdrsize		// whole header?
		bne !-
		stx hdroffs			// new header offset
		// do we have that sector already? (tested on VICE that there is enough time to check it before sector sync even on the fastest speedzone (track 35))
		ldx hdroffsold
		beq ReadGCRSector	// it's first sector, nothing to compare with
		ldy #0
!:		lda RE_cached_headers+1,x	// skip magic value byte
		cmp RE_cached_headers+1,y
		bne ReadGCRSector
		inx
		iny
		cpy #3				// last few bytes are identical too
		bne !-
		jmp DecodeHeaders	// yes, no need to read more

ReadGCRSector:
		jsr LF556			// wait for SYNC, will set Y=0
!:		bvc !-
		clv
		lda $1c01
		sta (bufpage),y
		iny
		bne !-
		ldx #$BA			// write rest: in ROM from $1BA to $1FF, here we just count it up
		ldy #0
!:		bvc !-
		clv
		lda $1c01
		sta (bufrest),y
		iny
		inx
		bne !-

		// adjust pointers
		inc bufpage+1
		inc counter
		lda bufrest
		clc
		adc #bufrestsize
		sta bufrest
		bcc !+
		inc bufrest+1
!:		lda counter
		cmp #maxsector		// do we have all sectors already? (should be never equal)
		beq DecodeHeaders	// this jump should be never taken
		jmp ReadHeader		// not all sectors, read the next one

DecodeHeaders:
		// we don't need to decode GCR sector data right now, but we need those sector numbers
		// so go through all headers and decode them, put them back
		ldx #0
		stx bufrest			// reuse for counter
		stx hdroffs

		lda BUFPNT
		pha
		lda BUFPNT+1
		pha

		lda #<RE_cached_headers
		sta BUFPNT
		lda #>RE_cached_headers
		sta BUFPNT+1

DecodeLoop:
		// fast partial header decode, without copying (formerly LF497)
		lda hdroffs
		sta $34				// offset
		jsr L98D9			// decode 5 GCR bytes into 4 BIN cells

		// XXX check header checksum here to mark mangled sector headers?
		ldx bufrest
		lda $54				// sector
		sta RE_cached_headers,x	// store decoded sector number
		lda hdroffs			// next header data offset
		clc
		adc #hdrsize
		sta hdroffs
		inx
		stx bufrest			// next header counter
		cpx counter
		bne DecodeLoop

		stx RE_max_sector
		pla
		sta BUFPNT+1
		pla
		sta BUFPNT

		// all was said and done, now read the sector from cache
		jmp ReadSector

/////////////////////////////////////
// 1571

// 9965 / F8E0 - direct copy of F8E0 but jumps to 98D9 instead of F7E6 called from sector read routine, decode GCR data from ($30/31)+$01BA-$FF into ($30/31)
LF8E0:	{
		lda #$00
		sta $34
		sta $2E
		sta $36
		lda #$01
		sta $4E
		lda #$BA
		sta $4F
		lda BUFPNT+1
		sta $2F
		jsr L98D9
		lda $52
		sta $38
		ldy $36
		lda $53
		sta ($2E),Y
		iny
		lda $54
		sta ($2E),Y
		iny
		lda $55
		sta ($2E),Y
		iny
L9991:	sty $36
		jsr L98D9
		ldy $36
		lda $52
		sta ($2E),Y
		iny
		beq L99B0
		lda $53
		sta ($2E),Y
		iny
		lda $54
		sta ($2E),Y
		iny
		lda $55
		sta ($2E),Y
		iny
		bne L9991
L99B0:	lda $53			// not in 1571 code
		sta $3A			// not in 1571 code
		lda $2F
		sta BUFPNT+1
		rts
}

// 952F / F497 - direct copy of F497 but jumps to 98D9 instead of F7E6

LF497:	{					// decode 10 GCR bytes from $24 into header structure at $16-$1A (track at $18, sector at $19, $16/$17=ID, $1A=checksum)
		lda BUFPNT
		pha
		lda BUFPNT+1
		pha
		lda #<STAB			// pointer $30/31 to $0024
		sta BUFPNT
		lda #>STAB
		sta BUFPNT+1
		sta $34				// initial offset
		jsr L98D9			// decode 5 GCR bytes into 4 BIN cells
		lda $55
		sta HEADER+2		// $18 track
		lda $54
		sta HEADER+3		// $19 sector
		lda $53
		sta HEADER+4		// $1A checksum
		jsr L98D9			// decode next 5 GCR bytes into 4 BIN cells
		lda $52
		sta HEADER+1		// $17 ID2
		lda $53
		sta HEADER			// $16 ID1
		pla
		sta BUFPNT+1
		pla
		sta BUFPNT
		rts
}

// 98D9 / F7E6 - Convert 5 GCR bytes from ($30),Y (Y=$34); $30 must be 0, after Y rollover into ($4E->$31 (hi), $4F->Y (lo), $01BB) into 4 binary bytes into $52-$55, $56-$5D used for temp storage
L98D9:	{
		ldy $34
		lda (BUFPNT),Y
		sta $56
		and #$07
		sta $57
		iny
		bne L98EC
		lda $4E
		sta BUFPNT+1
		ldy $4F
L98EC:	lda (BUFPNT),Y
		sta $58
		and #$C0
		ora $57
		sta $57
		lda $58
		and #$01
		sta $59
		iny
		lda (BUFPNT),Y
		tax
		and #$F0
		ora $59
		sta $59
		txa
		and #$0F
		sta $5A
		iny
		lda (BUFPNT),Y
		sta $5B
		and #$80
		ora $5A
		sta $5A
		lda $5B
		and #$03
		sta $5C
		iny
		bne L9927
		lda $4E
		sta BUFPNT+1
		ldy $4F
L9927:	lda (BUFPNT),Y
		sta $5D
		and #$E0
		ora $5C
		sta $5C
		iny
		sty $34
		ldx $56
		lda LA00D,X
		ldx $57
		ora L9F0D,X
		sta $52
		ldx $58
		lda LA10D,X
		ldx $59
		ora L9F0F,X
		sta $53
		ldx $5A
		lda L9F1D,X
		ldx $5B
		ora LA20D,X
		sta $54
		ldx $5C
		lda L9F2A,X
		ldx $5D
		ora LA30D,X
		sta $55
		rts
}

// 98D9 / F7E6 - Convert 5 GCR bytes from ($30),Y (Y=$34); $30 must be 0, after Y rollover into ($4E->$31 (hi), $4F->Y (lo), $01BB) into 4 binary bytes into $52-$55, $56-$5D used for temp storage
// almost the same as 98D9 but allow for any offset, BUFPNT AND BUFPNT+1 can be overwriten
Decode5GCR:	{
		ldy $34
		lda (bufpage),Y
		sta $56
		and #$07
		sta $57
		iny
		bne !+
		jsr CopyRestVector
!:		lda (bufpage),Y
		sta $58
		and #$C0
		ora $57
		sta $57
		lda $58
		and #$01
		sta $59
		iny
		bne !+
		jsr CopyRestVector
!:		lda (bufpage),Y
		tax
		and #$F0
		ora $59
		sta $59
		txa
		and #$0F
		sta $5A
		iny
		bne !+
		jsr CopyRestVector
!:		lda (bufpage),Y
		sta $5B
		and #$80
		ora $5A
		sta $5A
		lda $5B
		and #$03
		sta $5C
		iny
		bne !+
		jsr CopyRestVector
!:		lda (bufpage),Y
		sta $5D
		and #$E0
		ora $5C
		sta $5C
		iny
		bne !+
		jsr CopyRestVector
!:		sty $34
		ldx $56
		lda LA00D,X
		ldx $57
		ora L9F0D,X
		sta $52
		ldx $58
		lda LA10D,X
		ldx $59
		ora L9F0F,X
		sta $53
		ldx $5A
		lda L9F1D,X
		ldx $5B
		ora LA20D,X
		sta $54
		ldx $5C
		lda L9F2A,X
		ldx $5D
		ora LA30D,X
		sta $55
		rts

CopyRestVector:
		lda bufrest+1
		sta bufpage+1
		lda bufrest
		sta bufpage
		rts
}

/////////////////////////////////////

#if ROMSPEEDDOS35 || ROMSPEEDDOS40
		// this will be called via M-E from C64 Kernal
		// file was opened t&s is in $18/19
		// all RAM can be used (SpeedDOS puts its own code in $0300-$0500 while $0600-$0700 and $0140-FF are for data buffers)
SpeedDOSLoader:
		ldx #$FF					// <--- START, $18/19 has file starting t&s
		stx $1803					// PA out
		inx
		stx $0F
		lda #$0B
		sta $180C					// handshake
		bne SpeedDOSNextSector		// skip over first data load - that track is already cached

L0313:	lda $18
		sta $06
		lda $19
		sta $07
		lda #$80					// read first sector - track is now fully cached
		sta $00
!:		lda $00
		bmi !-
		cmp #$01
		bne SpeedDOSEOF				// error = end of transmission

SpeedDOSNextSector:
		// $19 contains sector number, find it in cache and update vector $30 (probably $0300 all the time)
		jsr ReadCacheFindSector

		// send sectors (updating $18/$19) from current track cache until end of file or track change
		ldy #0
		lda (BUFPNT),Y
		bne L043B					// non-zero track, this is not the last sector
		iny
		lda (BUFPNT),Y				// number of bytes in the last sector
		jsr SpeedDOSSendBlock		// send it out
		jmp SpeedDOSEOF

L043B:	tax							// preserve next track number in X
		iny
		lda (BUFPNT),Y
		sta $19						// next sector
		lda #$FF
		jsr SpeedDOSSendBlock		// send out $FE bytes from current buffer
		cpx $18						// next track the same?
		beq SpeedDOSNextSector		// yes: send next sector
		stx $18						// no: new track
		bne L0313

SpeedDOSEOF:
L0333:	lda #$00					// 00 = end of file (0 bytes to follow)
		jsr SpeedDOSSendByte		// send byte
		lda $00
		pha
		jsr SpeedDOSSendByte		// send status byte, 01=no error
		inc $1803					// PA input
		lda $18						// track & sector (header)
		pha
		lda $19
		pha
		jsr $D005					// disk init (why? to return head to directory? to bring back BAM 18,0 into buffer $0700?)
		pla
		sta $80						// current track & sector (why put it back, we're not on original track anymore)
		pla
		sta $81
		pla
		cmp #$01					// error?
		bne L035B					// yes
		jmp $D313					// no: Close all channels of other drives
L035B:	clc							// error number
		adc #$1E
		jmp $E645					// Print error message into error buffer

SpeedDOSSendByte:					// send byte with watchdog reset
L0405:  bit $1800					// send byte ; clear handshake
		sta $1801					// send byte
		ldy #$E0					// timeout
L040D:	lda $180D					// wait for handshake
		and #$10
		bne L041A
		iny
		bne L040D
		jmp $EAA0					// timeout->RESET
L041A:	rts							// ok

SpeedDOSSendBlock:
L0482:	sta $0C						// send out number of bytes that follow
		jsr L0405
		ldy #$01					// send out sector data
L0489:	iny
		lda (BUFPNT),Y
		bit $1800					// clear flag
		sta $1801
		lda #$10					// wait for handshake
L0494:	bit $180D
		beq L0494
		cpy $0C						// number of bytes to send
		bne L0489
		rts

		// all of that again because at the end we need RTS, not JMP
ReadCacheFindSector:
		lda $19
		sta hdroffs
		// setup pointers
		lda #>RAMEXP			// pages - first 256 bytes
		sta bufpage+1
		lda #>RAMEXP_REST		// remainders - following bytes until end of sector ($46 bytes)
		sta bufrest+1
		lda #0
		sta bufpage
		sta bufrest
		// find sector
		ldx #0
!loop:	lda RE_cached_headers,x
		cmp hdroffs
		beq !found+
		// no, next one
		inc bufpage+1
		lda bufrest
		clc
		adc #bufrestsize
		sta bufrest
		bcc !+
		inc bufrest+1
!:		inx
		cpx RE_max_sector
		bne !loop-
		rts						// not found - no possible? XXX

!found:
		// decode GCR sector data
		{
		lda #$00		// customized LF8E0 / 9965
		sta $34
		sta $2E
		sta $36
		lda BUFPNT+1	// write to here
		sta $2F
		jsr Decode5GCR	// customized 98D9 / F7E6
		lda $52
		sta $38
		ldy $36
		lda $53
		sta ($2E),Y
		iny
		lda $54
		sta ($2E),Y
		iny
		lda $55
		sta ($2E),Y
		iny
L9991:	sty $36
		jsr Decode5GCR
		ldy $36
		lda $52
		sta ($2E),Y
		iny
		beq L99B0
		lda $53
		sta ($2E),Y
		iny
		lda $54
		sta ($2E),Y
		iny
		lda $55
		sta ($2E),Y
		iny
		bne L9991
L99B0:	lda $53			// not in 1571 code
		sta $3A			// not in 1571 code
		}
		// XXX there is no checksum check here
		rts

#endif

/////////////////////////////////////

		// align tables to full page to avoid cross-page cycle penalty
		.align $0100
L9F0D:	.byte $0c, $04
L9F0F:	.byte $05, $ff, $ff, $02, $03, $ff, $0f, $06, $07, $ff, $09, $0a, $0b, $ff
L9F1D:	.byte $0d, $0e, $80, $ff, $00, $00, $10, $40, $ff, $20, $c0, $60, $40

L9F2A:	.byte $a0, $50, $e0, $ff, $ff, $ff, $02, $20, $08, $30, $ff, $ff, $00, $f0, $ff, $60
		.byte $01, $70, $ff, $ff, $ff, $90, $03, $a0, $0c, $b0, $ff, $ff, $04, $d0, $ff, $e0
		.byte $05, $80, $ff, $90, $ff, $08, $0c, $ff, $0f, $09, $0d, $80, $02, $ff, $ff, $ff
		.byte $03, $ff, $ff, $00, $ff, $ff, $0f, $ff, $0f, $ff, $ff, $10, $06, $ff, $ff, $ff
		.byte $07, $00, $20, $a0, $ff, $ff, $06, $ff, $09, $ff, $ff, $c0, $0a, $ff, $ff, $ff
		.byte $0b, $ff, $ff, $40, $ff, $ff, $07, $ff, $0d, $ff, $ff, $50, $0e, $ff, $ff, $ff
		.byte $ff, $10, $30, $b0, $ff, $00, $04, $02, $06, $0a, $0e, $80, $ff, $ff, $ff, $ff
		.byte $ff, $ff, $ff, $20, $ff, $08, $09, $80, $10, $c0, $50, $30, $30, $f0, $70, $90
		.byte $b0, $d0, $ff, $ff, $ff, $00, $0a, $ff, $ff, $ff, $ff, $f0, $00, $ea, $b5, $00
		.byte $30, $fc, $60, $60, $ff, $01, $0b, $ff, $ff, $ff, $ff, $70, $ff, $ff, $ff, $ff
		.byte $ff, $c0, $f0, $d0, $ff, $01, $05, $03, $07, $0b, $ff, $90, $ff, $ff, $ff, $ff
		.byte $ff, $ff, $ff, $a0, $ff, $0c, $0d, $ff, $ff, $ff, $ff, $b0, $ff, $ff, $ff, $ff
		.byte $ff, $40, $60, $e0, $ff, $04, $0e, $ff, $ff, $ff, $ff, $d0, $ff, $ff, $ff, $ff
		.byte $ff, $ff, $ff, $e0, $ff, $05, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff
		.byte $ff, $50, $70

LA00D:	.byte $0c, $04, $05, $ff, $ff, $02, $03, $ff, $0f, $06, $07, $ff, $09, $0a, $0b, $ff
		.byte $0d, $0e, $80, $ff, $00, $00, $10, $40, $ff, $20, $c0, $60, $40, $a0, $50, $e0
		.byte $ff, $ff, $ff, $02, $20, $08, $30, $30, $30, $00, $f0, $ff, $60, $01, $70, $ff
		.byte $ff, $ff, $90, $03, $a0, $0c, $b0, $ff, $ff, $04, $d0, $ff, $e0, $05, $80, $ff
		.byte $90, $ff, $08, $0c, $ff, $0f, $09, $0d, $80, $80, $80, $80, $80, $80, $80, $80
		.byte $00, $00, $00, $00, $00, $00, $00, $00, $10, $10, $10, $10, $10, $10, $10, $10
		.byte $a0, $ff, $ff, $06, $ff, $09, $ff, $ff, $c0, $c0, $c0, $c0, $c0, $c0, $c0, $c0
		.byte $40, $40, $40, $40, $40, $40, $40, $40, $50, $50, $50, $50, $50, $50, $50, $50
		.byte $b0, $ff, $00, $04, $02, $06, $0a, $0e, $80, $80, $80, $80, $80, $80, $80, $80
		.byte $20, $20, $20, $20, $20, $20, $20, $20, $30, $30, $30, $30, $30, $30, $30, $30
		.byte $ff, $ff, $00, $0a, $0a, $0a, $0a, $0a, $f0, $f0, $f0, $f0, $f0, $f0, $f0, $f0
		.byte $60, $60, $60, $60, $60, $60, $60, $60, $70, $70, $70, $70, $70, $70, $70, $70
		.byte $d0, $ff, $01, $05, $03, $07, $0b, $ff, $90, $90, $90, $90, $90, $90, $90, $90
		.byte $a0, $a0, $a0, $a0, $a0, $a0, $a0, $a0, $b0, $b0, $b0, $b0, $b0, $b0, $b0, $b0
		.byte $e0, $ff, $04, $0e, $ff, $ff, $ff, $ff, $d0, $d0, $d0, $d0, $d0, $d0, $d0, $d0
		.byte $e0, $e0, $e0, $e0, $e0, $e0, $e0, $e0, $05, $05, $05, $05, $05, $05, $50, $70

LA10D:	.byte $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff
		.byte $ff, $ff, $80, $80, $00, $00, $10, $10, $ff, $ff, $c0, $c0, $40, $40, $50, $50
		.byte $ff, $ff, $ff, $ff, $20, $20, $30, $30, $ff, $ff, $f0, $f0, $60, $60, $70, $70
		.byte $ff, $ff, $90, $90, $a0, $a0, $b0, $b0, $ff, $ff, $d0, $d0, $e0, $e0, $ff, $ff
		.byte $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff
		.byte $ff, $ff, $80, $80, $00, $00, $10, $10, $ff, $ff, $c0, $c0, $40, $40, $50, $50
		.byte $ff, $ff, $ff, $ff, $20, $20, $30, $30, $ff, $ff, $f0, $f0, $60, $60, $70, $70
		.byte $ff, $ff, $90, $90, $a0, $a0, $b0, $b0, $ff, $ff, $d0, $d0, $e0, $e0, $ff, $ff
		.byte $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff
		.byte $ff, $ff, $80, $80, $00, $00, $10, $10, $ff, $ff, $c0, $c0, $40, $40, $50, $50
		.byte $ff, $ff, $ff, $ff, $20, $20, $30, $30, $ff, $ff, $f0, $f0, $60, $60, $70, $70
		.byte $ff, $ff, $90, $90, $a0, $a0, $b0, $b0, $ff, $ff, $d0, $d0, $e0, $e0, $ff, $ff
		.byte $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff
		.byte $ff, $ff, $80, $80, $00, $00, $10, $10, $ff, $ff, $c0, $c0, $40, $40, $50, $50
		.byte $ff, $ff, $ff, $ff, $20, $20, $30, $30, $ff, $ff, $f0, $f0, $60, $60, $70, $70
		.byte $ff, $ff, $90, $90, $a0, $a0, $b0, $b0, $ff, $ff, $d0, $d0, $e0, $e0, $ff, $ff

LA20D:	.byte $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff
		.byte $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff
		.byte $ff, $ff, $ff, $ff, $08, $08, $08, $08, $00, $00, $00, $00, $01, $01, $01, $01
		.byte $ff, $ff, $ff, $ff, $0c, $0c, $0c, $0c, $04, $04, $04, $04, $05, $05, $05, $05
		.byte $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $02, $02, $02, $02, $03, $03, $03, $03
		.byte $ff, $ff, $ff, $ff, $0f, $0f, $0f, $0f, $06, $06, $06, $06, $07, $07, $07, $07
		.byte $ff, $ff, $ff, $ff, $09, $09, $09, $09, $0a, $0a, $0a, $0a, $0b, $0b, $0b, $0b
		.byte $ff, $ff, $ff, $ff, $0d, $0d, $0d, $0d, $0e, $0e, $0e, $0e, $ff, $ff, $ff, $ff
		.byte $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff
		.byte $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff
		.byte $ff, $ff, $ff, $ff, $08, $08, $08, $08, $00, $00, $00, $00, $01, $01, $01, $01
		.byte $ff, $ff, $ff, $ff, $0c, $0c, $0c, $0c, $04, $04, $04, $04, $05, $05, $05, $05
		.byte $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $02, $02, $02, $02, $03, $03, $03, $03
		.byte $ff, $ff, $ff, $ff, $0f, $0f, $0f, $0f, $06, $06, $06, $06, $07, $07, $07, $07
		.byte $ff, $ff, $ff, $ff, $09, $09, $09, $09, $0a, $0a, $0a, $0a, $0b, $0b, $0b, $0b
		.byte $ff, $ff, $ff, $ff, $0d, $0d, $0d, $0d, $0e, $0e, $0e, $0e, $ff, $ff, $ff, $ff

LA30D:	.byte $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $08, $00, $01, $ff, $0c, $04, $05
		.byte $ff, $ff, $02, $03, $ff, $0f, $06, $07, $ff, $09, $0a, $0b, $ff, $0d, $0e, $ff
		.byte $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $08, $00, $01, $ff, $0c, $04, $05
		.byte $ff, $ff, $02, $03, $ff, $0f, $06, $07, $ff, $09, $0a, $0b, $ff, $0d, $0e, $ff
		.byte $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $08, $00, $01, $ff, $0c, $04, $05
		.byte $ff, $ff, $02, $03, $ff, $0f, $06, $07, $ff, $09, $0a, $0b, $ff, $0d, $0e, $ff
		.byte $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $08, $00, $01, $ff, $0c, $04, $05
		.byte $ff, $ff, $02, $03, $ff, $0f, $06, $07, $ff, $09, $0a, $0b, $ff, $0d, $0e, $ff
		.byte $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $08, $00, $01, $ff, $0c, $04, $05
		.byte $ff, $ff, $02, $03, $ff, $0f, $06, $07, $ff, $09, $0a, $0b, $ff, $0d, $0e, $ff
		.byte $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $08, $00, $01, $ff, $0c, $04, $05
		.byte $ff, $ff, $02, $03, $ff, $0f, $06, $07, $ff, $09, $0a, $0b, $ff, $0d, $0e, $ff
		.byte $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $08, $00, $01, $ff, $0c, $04, $05
		.byte $ff, $ff, $02, $03, $ff, $0f, $06, $07, $ff, $09, $0a, $0b, $ff, $0d, $0e, $ff
		.byte $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $ff, $08, $00, $01, $ff, $0c, $04, $05
		.byte $ff, $ff, $02, $03, $ff, $0f, $06, $07, $ff, $09, $0a, $0b, $ff, $0d, $0e, $ff
