/* Fantasi / Chameleon Ultra (nRF52840)
 *
 * The stock Chameleon Ultra firmware ships with MBR (0x0-0x1000),
 * SoftDevice S140 v7.2.0 (0x1000-0x27000) and a DFU bootloader above
 * the app (around 0xF3000-0x100000). We link our app at the same
 * 0x27000 offset the DFU bootloader expects, and we do NOT overwrite
 * any flash below 0x27000. This preserves the bootloader (which is
 * the only path to recovery without a J-Link) and the MBR.
 *
 * At runtime the Reset_Handler re-points VTOR to our vector table so
 * the SoftDevice sitting in flash is effectively inert - we never call
 * its API and never route interrupts through it.
 *
 * RAM starts at 0x20002ae8: the region below is where the SoftDevice
 * keeps state during boot / handoff. Matches the stock app.ld to stay
 * compatible with the DFU bootloader's RAM expectations.
 */

ENTRY(Reset_Handler)

_stack_size = 0x1000;   /* 4 KB */

MEMORY {
    /* 816 KB total app flash, 256 KB reserved at top for LittleFS.
     * Storage base is detected at runtime from UICR bootloader address. */
    FLASH (rx)  : ORIGIN = 0x00027000, LENGTH = 0x8C000   /* 560 KB */
    RAM   (rwx) : ORIGIN = 0x20005000, LENGTH = 0x3B000   /* ~236 KB (256K - SoftDevice w/MTU 247 + DLE) */
}

_stack_end = ORIGIN(RAM) + LENGTH(RAM);

_ram_start = ORIGIN(RAM);
_ram_end   = ORIGIN(RAM) + LENGTH(RAM);

SECTIONS {
    .isr_vector : {
        . = ALIGN(4);
        KEEP(*(.isr_vector))
        . = ALIGN(4);
    } >FLASH

    .text : {
        . = ALIGN(4);
        *(.text .text.*)
        *(.glue_7) *(.glue_7t)
        KEEP(*(.init)) KEEP(*(.fini))
        . = ALIGN(4);
        _etext = .;
    } >FLASH

    .rodata : {
        . = ALIGN(4);
        *(.rodata .rodata.*)
        . = ALIGN(4);
    } >FLASH

    .ARM.extab : { *(.ARM.extab* .gnu.linkonce.armextab.*) } >FLASH
    .ARM : {
        __exidx_start = .;
        *(.ARM.exidx*)
        __exidx_end = .;
    } >FLASH

    .preinit_array : {
        PROVIDE_HIDDEN (__preinit_array_start = .);
        KEEP(*(.preinit_array*))
        PROVIDE_HIDDEN (__preinit_array_end = .);
    } >FLASH
    .init_array : {
        PROVIDE_HIDDEN (__init_array_start = .);
        KEEP(*(SORT(.init_array.*))) KEEP(*(.init_array*))
        PROVIDE_HIDDEN (__init_array_end = .);
    } >FLASH
    .fini_array : {
        PROVIDE_HIDDEN (__fini_array_start = .);
        KEEP(*(SORT(.fini_array.*))) KEEP(*(.fini_array*))
        PROVIDE_HIDDEN (__fini_array_end = .);
    } >FLASH

    _sidata = LOADADDR(.data);

    .data : {
        . = ALIGN(4);
        _sdata = .;
        *(.data .data.*)
        . = ALIGN(4);
        _edata = .;
    } >RAM AT> FLASH

    _eflash = LOADADDR(.data) + SIZEOF(.data);

    .bss : {
        . = ALIGN(4);
        _sbss = .;
        __bss_start__ = .;
        *(.bss .bss.*) *(COMMON)
        . = ALIGN(4);
        _ebss = .;
        __bss_end__ = .;
        end = .;                    /* _sbrk anchor. The ._user_heap_stack region
                                     * below is the FreeRTOS app heap: ucHeap is
                                     * aliased onto __heap_start__ and libc malloc
                                     * is wrapped onto it, so _sbrk stays unused. */
        PROVIDE(_end = .);
    } >RAM

    /* Collect the picolibc TLS template (errno, rand state, localtime buffer)
     * into one explicitly-defined section so the ASSERT below can size it on any
     * toolchain: a bare SIZEOF(.tdata) errors out when a picolibc build emits no
     * .tdata. (INFO) keeps it out of the loadable image; placed here (RAM still
     * has room) it doesn't overlay a real section. We don't use the template at
     * runtime anyway - TLS lives in core/libc_glue.c's fantasi_tls_block via our
     * own __aeabi_read_tp - this exists only to be sized. */
    .tls_sizecheck (INFO) : {
        *(.tdata .tdata.*)
        *(.tbss .tbss.*)
    }

    ._user_heap_stack (NOLOAD) : {
        . = ALIGN(8);
        __heap_start__ = .;
        . = ORIGIN(RAM) + LENGTH(RAM) - _stack_size;
        __heap_end__ = .;
        . = . + _stack_size;
        . = ALIGN(8);
    } >RAM

    /DISCARD/ : { *(.ARM.attributes) *(.comment) *(.note.GNU-stack) }
}

/* The picolibc TLS template must fit in core/libc_glue.c's fantasi_tls_block[128]
 * minus the 8-byte ARM EABI TCB. Fail the build if a new TLS consumer outgrows it
 * instead of overrunning the block at runtime. .tls_sizecheck is always defined
 * (above), so SIZEOF resolves even when the toolchain emits no .tdata/.tbss. */
ASSERT(SIZEOF(.tls_sizecheck) <= 120,
       "picolibc TLS exceeds fantasi_tls_block (core/libc_glue.c)")
