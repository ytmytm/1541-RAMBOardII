
# 1571-TrackCacheROM

This is a patch for the 1571 firmware that utilizes drive RAM expansion to cache the current track.

Patched ROMs for standalone 1571 and internal 1571 (from C128D) are provided here in the repository. Both of them use $6000-$7FFF as expanded RAM area.

You can also patch JiffyDOS ROMs yourself.

# Background

There is not much use for a 1571 disk drive with expanded RAM. About the only use case I could think of was GCR Nibbler with RAMBOard option from Maverick V5.

I knew that 1581 does cache whole tracks at once. I was curious how a 1571 with track cache would perform.

# Hardware

A stock 1571 disk drive, just like the 1541, has only 2K of SRAM in the range $0000-$07FF. This project requires at least 8K more.

For a C128DCR, you can use my [other project](https://github.com/ytmytm/c128-bytewide-color-ram-1571cr-expansion)

I don't know if this procedure is equally simple for a standalone 1571, but there are [various other options available](http://d81.de/CLD-RAMBOard/References.shtml).

# Configuration and assembly

(Note: if you want to try it out **now** just download one of the stock `...-patched.bin` files)

You need [KickAss](http://www.theweb.dk/KickAssembler/Main.html#frontpage) to assemble this code.

There is only one file here: [rampatch.asm](rampatch.asm). It reads a ROM as an input, applies patches and saves the result.

In the [rom/](rom) folder I have provided two inputs: stock ROM images for standalone 1571 drive (310654-05) and for C128D's internal 1571CR drive (318047-01).

The same code can be used to patch JiffyDOS, but you need to provide ROM images yourself.

On the top of the [rampatch.asm](rampatch.asm) file there are configuration options:

- `RAMEXP` - the basis address of 8K area of expanded RAM, by default $6000 for $6000-$7FFF range
- uncomment one of the defines to choose which ROM image will be patched:

Assemble the file to get patched ROM as a result. The ROM choice definition can also be passed on the command line:

```sh
java -jar <path-to>/KickAss.jar rampatch.asm -showmem -define ROM1571
```

Flash the result onto a 32K EEPROM and try it out.

# Results

There is no indication that new code is in place. I didn't change the drive behaviour or RESET message.

One thing that **will change** is the speed of **V**alidate command. You will hear that with the new ROM it's much faster, large files will be scanned with head moving across the tracks almost as fast as the format operation.

I have tried the benchmark program used for [Comparison of fastloaders](https://www.c64-wiki.com/wiki/Comparison_of_fast_loaders).
Except for **V**alidate and **S**cratch being 3-4 times faster it shows that not much have changed.

## So is there any benefit?

It depends. The main benefit is that all the files are read with constant, optimal speed. The sector interleave doesn't matter anymore.

JiffyDOS operates best with different interleave than stock Commodore ROM. With this patch it doesn't matter.

This patch gives marginal (maybe 5% or less) speed increase when file was saved with optimal sector interleave.

If sector interleave is suboptimal both JiffyDOS and stock CBM ROM performance will suffer, with interleave set to a ridiculous value of 1 the load time will be even twice as
long on a stock ROM. With this patch it doesn't matter - it will load with the same, fastest possible speed as always.

Note that this applies if you are using C128 native mode (with or without JiffyDOS) or C64 mode with JiffyDOS.
A stock C64 Kernal will be as slow as ever because the data transfer is the bottleneck here.

# Theory of operation

There are two main patched routines. Both are called from job code $80 (sector read) - in native 1571 mode and in 1541 mode.

Depending on the mode the cache works in a different way.

## Sector read

Any time a sector read is requested we check if that track is already cached. If it is cached then for JiffyDOS we also need to check if cache contains GCR encoded data (that we need to decode) or if it was already decoded. Then we copy the result into target buffer.

If requested track is not yet cached we read all the incoming data within one disk revolution. With 300rpm that will take 200ms. Any further reads from that track will come from the cache.

### Sector headers and disk revolution detection

Track reading starts with waiting for a sync signal and then for the first sector header. There is no time to decode the header at this moment so we just keep it as raw GCR in a buffer.

We also need to identify if a disk did a whole revolution already. This could be done by checking how many sectors we should expect, depending on the track number.
Instead I opted just for checking if the currently read header is the same as the very first one we saw.

### 1541 mode

Here 1571 works exactly like 1541 with 1MHz clock. There is no time to decode GCR on the fly, so we store incoming data as raw GCR. The first 256 bytes go into buffers that start at $6000 and go up page by page. The remaining part (data and sector checksum) normally stored in work area $01BA-$01FF go into a sliding buffer in the upper section of the expanded RAM.

### 1571 mode

In native 1571 mode CPU has 2MHz clock. There are tables in ROM and there is enough time to decode GCR on the fly, so we store incoming data as binary. Each page of memory that starts at $6000 contains already decoded sector data. We just don't know which one is which as the sector headers were not converted from GCR into binary yet.

### Housekeeping

Once the code detects that we already saw that sector header (or if it hits the limit of 23 sectors, which should never happen) we know that we saw a whole track.

We need to know in which order the sectors have been decoded, so now we need to decode all sector headers from GCR into binary and keep a list of their numbers. This way we know where to find that sector's data in the RAM expansion.

If we have GCR data read in 1541 mode we don't decode it immediately - it would take some time and we don't know if that data is needed at all. It's much simpler to keep it as GCR and (when requested) copy that GCR data into place where ROM routines would read it off the disk and continue in ROM.

## Other patched routines

All the other patches are needed to indicate that the cache is no longer valid. This is done by putting $FF as the number of currently cached track.

These patches are applied on:

- the code that processes drive job commands to check if track has changed
- the code that runs after drive power-up or reset
- disk initialization 'I' command
- drive mode switching between 1541 and 1571 (`U0>M0` and `U0>M1`)

## JiffyDOS

JiffyDOS patches the 1571 ROM in a way that causes it in 1571 mode to call 1541 read routine instead of native 1571 code. Because of that we need to track in which mode (GCR or decoded binary) the current cache is stored and act accordingly.

# Conclusions

Now I completely understand why CBM kept only 2K of RAM in the 1571. There is not much to gain for (probably a lot) the cost of larger SRAM chip back in 1986.

However, if you already have a 1571 with expanded RAM and you use your C128 in native mode, I highly recommend it.

You will see absolutely no change if you mostly work in C64 mode with some kind of fastload cartridge.

# What about 1541?

After disabling parts that are 1571-specific, the same code will work just as well on a 1541 with expanded RAM.

The problem is that on a stock 1541, there is not enough unused space in the ROM area to put these patches.
So something would have to be disabled, for example REL file support.
