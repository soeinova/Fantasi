/* Fantasi / Flipper Zero (STM32WB55RG)
 *
 * Flash starts at 0x08000000. On the Flipper, the ROM bootloader lives
 * above user flash in the STM32WB system memory area, not here, so we
 * link at 0x08000000. Writing to the first page still leaves the ROM
 * DFU intact - that's our recovery path.
 *
 * RAM1 begins at 0x20000008: the first eight bytes of SRAM1 are reserved
 * for STM32WB handoff info (see RM0434 §4.2.2). Touching those bricks
 * the dual-core handoff. RAM2A / RAM2B are for the CPU2 (BLE) firmware
 * and we do not map anything there.
 */

ENTRY(Reset_Handler)

_stack_size = 0x1000;   /* 4 KB main/IRQ stack */

MEMORY {
    /* Firmware region. Storage (256 KB LittleFS) is placed at runtime
     * just below the BLE secure boundary (SFSA), so it lives above this
     * region.  512 KB here is a safe upper bound - the runtime init in
     * flash_storage.c verifies no overlap. */
    FLASH  (rx)  : ORIGIN = 0x08000000, LENGTH = 512K
    RAM1   (xrw) : ORIGIN = 0x20000008, LENGTH = 0x2FFF8   /* ~192K - 8 */
    SRAM2A (xrw) : ORIGIN = 0x20030000, LENGTH = 32K       /* shared with CPU2 BLE */
}

_stack_end = ORIGIN(RAM1) + LENGTH(RAM1);   /* top-of-stack for vector[0] */

_ram1_start   = ORIGIN(RAM1);
_ram1_end     = ORIGIN(RAM1) + LENGTH(RAM1);
_sram2a_start = ORIGIN(SRAM2A);
_sram2a_end   = ORIGIN(SRAM2A) + LENGTH(SRAM2A);

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
    } >RAM1 AT> FLASH

.tdata : {
        . = ALIGN(4);
        __tdata_start = .;
        *(.tdata .tdata.*)
        . = ALIGN(4);
        __tdata_end = .;
    } >RAM AT> FLASH

    .tbss (NOLOAD) : {
        . = ALIGN(4);
        __tbss_start = .;
        *(.tbss .tbss.*)
        . = ALIGN(4);
        __tbss_end = .;
    } >RAM

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
    } >RAM1

    /* .noinit: SRAM that survives a warm reset and is NOT zeroed by
     * Reset_Handler. Used for the DFU handoff magic - writing it from
     * a running firmware and reading it again from early reset is the
     * only way to enter the ST system bootloader on this part (CPU2's
     * secure world blocks the 0x1FFF0000 jump from normal execution). */
    .noinit (NOLOAD) : {
        . = ALIGN(4);
        *(.noinit .noinit.*)
        . = ALIGN(4);
    } >RAM1

    ._user_heap_stack (NOLOAD) : {
        . = ALIGN(8);
        __heap_start__ = .;
        . = ORIGIN(RAM1) + LENGTH(RAM1) - _stack_size;
        __heap_end__ = .;
        . = . + _stack_size;
        . = ALIGN(8);
    } >RAM1

    /* IPCC mailbox shared with CPU2 (M0+ BLE stack).
     * .mapping_table MUST start at SRAM2A origin - CPU2 reads it as
     * a fixed address (AN5289 §4.2). */
    .mapping_table (NOLOAD) : ALIGN(4) {
        KEEP(*(.mapping_table))
    } >SRAM2A

    .mb_mem1 (NOLOAD) : ALIGN(4) {
        *(.mb_mem1 .mb_mem1.*)
    } >SRAM2A

    .mb_mem2 (NOLOAD) : ALIGN(4) {
        *(.mb_mem2 .mb_mem2.*)
        _sram2a_used_end = .;
    } >SRAM2A

    /DISCARD/ : { *(.ARM.attributes) *(.comment) *(.note.GNU-stack) }
}

/* The picolibc TLS segment (errno, rand state, localtime buffer) must fit in
 * core/libc_glue.c's fantasi_tls_block[128] minus the 8-byte ARM EABI TCB. Fail
 * the build if a new TLS consumer outgrows it instead of corrupting .bss. */
ASSERT(SIZEOF(.tdata) + SIZEOF(.tbss) <= 120,
       "picolibc TLS segment exceeds fantasi_tls_block (core/libc_glue.c)")
