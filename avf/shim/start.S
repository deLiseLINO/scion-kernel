/*
 * avfboot entry: an arm64 Linux Image (Documentation/arch/arm64/booting.rst),
 * so crosvm (AVF) and QEMU's -kernel load and enter it like a Linux kernel:
 * EL1, MMU and D-cache off, x0 = physical address of the FDT.
 *
 * The image is linked at 0 as a PIE and relocates itself (R_AARCH64_RELATIVE)
 * before any C code runs: crosvm loads it at the start of RAM (0x80000000),
 * QEMU virt at 0x40000000.
 */
	.section .text.head, "ax"
	.globl _head
_head:
	b	_start			/* code0 */
	.long	0			/* code1 */
	.quad	0			/* text_offset: load at the 2MB-aligned base */
	.quad	_image_size		/* image_size, including .bss and the stack */
	.quad	0xa			/* flags: little endian, 4K pages, anywhere in RAM */
	.quad	0			/* res2 */
	.quad	0			/* res3 */
	.quad	0			/* res4 */
	.ascii	"ARM\x64"		/* magic */
	.long	0			/* res5 (no PE header) */

	.text
	.globl _start
_start:
	msr	daifset, #0xf
	mov	x19, x0			/* FDT */
	msr	spsel, #1
	adr	x1, vectors
	msr	vbar_el1, x1
	isb

	/* self-relocation: *(base + r_offset) = base + r_addend for R_AARCH64_RELATIVE */
	adr	x20, _head		/* load address = link-time 0 */
	adrp	x1, __rela_start
	add	x1, x1, :lo12:__rela_start
	adrp	x2, __rela_end
	add	x2, x2, :lo12:__rela_end
1:	cmp	x1, x2
	b.hs	2f
	ldp	x3, x4, [x1], #16	/* r_offset, r_info */
	ldr	x5, [x1], #8		/* r_addend */
	cmp	w4, #1027		/* R_AARCH64_RELATIVE */
	b.ne	1b
	add	x5, x5, x20
	str	x5, [x20, x3]
	b	1b
2:
	/* zero .bss */
	adrp	x1, __bss_start
	add	x1, x1, :lo12:__bss_start
	adrp	x2, __bss_end
	add	x2, x2, :lo12:__bss_end
3:	cmp	x1, x2
	b.hs	4f
	str	xzr, [x1], #8
	b	3b
4:	adrp	x1, __stack_top
	add	x1, x1, :lo12:__stack_top
	mov	sp, x1
	dsb	sy
	ic	iallu
	dsb	sy
	isb
	mov	x0, x19
	bl	avfboot_main
5:	wfe
	b	5b

/*
 * A core started with PSCI CPU_ON (avfboot_main hands the kernel to the biggest core): EL1,
 * MMU and caches off like the boot core. Jumps to hop_entry with x0 = hop_arg, as the boot
 * core would have.
 */
	.globl avfboot_hop
avfboot_hop:
	msr	daifset, #0xf
	adr	x9, vectors
	msr	vbar_el1, x9
	dsb	sy
	ic	iallu
	dsb	sy
	isb
	adrp	x9, kret_stack_top
	add	x9, x9, :lo12:kret_stack_top
	mov	sp, x9
	bl	avfboot_hop_main
	adrp	x1, hop_entry
	ldr	x1, [x1, :lo12:hop_entry]
	adrp	x0, hop_arg
	ldr	x0, [x0, :lo12:hop_arg]
	br	x1

/*
 * Diagnostic (avf_cachescan=): how many 64-byte lines of [lo, hi) read differently through a
 * cacheable mapping than RAM holds, i.e. stale lines in the data cache.
 *   uint64_t avfboot_stale_scan(uint64_t lo, uint64_t hi, uint64_t *l1, uint64_t alias, uint64_t *first)
 * l1: a 4 KB L1 table (39-bit VA, 4 KB granule, 1 GB blocks) mapping RAM at VA = PA with MAIR
 * index 0 (Normal write-back) and at VA = PA + alias with index 1 (Normal non-cacheable).
 * The MMU and data cache are on only inside the loop, which touches no memory but the range.
 */
	.globl avfboot_stale_scan
avfboot_stale_scan:
	mrs	x9, sctlr_el1
	mrs	x12, mair_el1
	mrs	x13, tcr_el1
	mrs	x14, ttbr0_el1
	mov	x10, #0x44ff		/* attr0 WB, attr1 NC */
	msr	mair_el1, x10
	mov	x11, #0x19		/* T0SZ 25, walks non-cacheable, 4 KB granule */
	movk	x11, #0x80, lsl #16	/* EPD1 */
	movk	x11, #2, lsl #32	/* IPS 40 bits */
	msr	tcr_el1, x11
	msr	ttbr0_el1, x2
	isb
	tlbi	vmalle1
	dsb	nsh
	isb
	mov	x15, #5			/* M, C */
	orr	x15, x9, x15
	mov	x5, #0
	mov	x6, #0
	msr	sctlr_el1, x15
	isb
1:	cmp	x0, x1
	b.hs	3f
	add	x7, x0, x3
	ldp	x8, x10, [x0]
	ldp	x11, x16, [x7]
	cmp	x8, x11
	ccmp	x10, x16, #0, eq
	b.ne	2f
	ldp	x8, x10, [x0, #16]
	ldp	x11, x16, [x7, #16]
	cmp	x8, x11
	ccmp	x10, x16, #0, eq
	b.ne	2f
	ldp	x8, x10, [x0, #32]
	ldp	x11, x16, [x7, #32]
	cmp	x8, x11
	ccmp	x10, x16, #0, eq
	b.ne	2f
	ldp	x8, x10, [x0, #48]
	ldp	x11, x16, [x7, #48]
	cmp	x8, x11
	ccmp	x10, x16, #0, eq
	b.ne	2f
	add	x0, x0, #64
	b	1b
2:	cbnz	x5, 4f
	mov	x6, x0
4:	add	x5, x5, #1
	add	x0, x0, #64
	b	1b
3:	msr	sctlr_el1, x9
	isb
	msr	mair_el1, x12
	msr	tcr_el1, x13
	msr	ttbr0_el1, x14
	isb
	tlbi	vmalle1
	dsb	nsh
	ic	iallu
	dsb	nsh
	isb
	str	x6, [x4]
	mov	x0, x5
	ret

/*
 * Diagnostic (avf_watch=): avfboot_mmu_on(l1) turns the MMU and caches on for good with that L1
 * table (MAIR attr0 write-back, attr1 non-cacheable, attr2 Device-nGnRnE; TCR as the scan's).
 */
	.globl avfboot_mmu_on
avfboot_mmu_on:
	mov	x10, #0x44ff
	msr	mair_el1, x10
	mov	x11, #0x19
	movk	x11, #0x80, lsl #16
	movk	x11, #2, lsl #32
	msr	tcr_el1, x11
	msr	ttbr0_el1, x0
	isb
	tlbi	vmalle1
	dsb	nsh
	isb
	mrs	x9, sctlr_el1
	orr	x9, x9, #1
	orr	x9, x9, #4
	orr	x9, x9, #0x1000
	msr	sctlr_el1, x9
	isb
	ret

/*
 * Diagnostic (avf_ckpt=): the kernel's loader return stub (its loader_stub_slot): entered with the
 * MMU off from start.s's LOADER_CHECKPOINT (x2 = 2, x3 = checkpoint) or its early exception
 * vector (x2 = 1, x3-x7 = ESR, ELR, FAR, LR, SP), or loader_return.c. Reports and powers off.
 */
	.globl avfboot_kreturn
avfboot_kreturn:
	msr	daifset, #0xf
	adrp	x9, kret_stack_top
	add	x9, x9, :lo12:kret_stack_top
	mov	sp, x9
	bl	avfboot_kernel_returned
7:	wfe
	b	7b

	.bss
	.balign	16
kret_stack:
	.space	0x2000
kret_stack_top:
	.text

/*
 * Diagnostic (avf_trapvec=VA of the kernel's ExceptionVectorsBase): copied over its synchronous
 * vectors (current EL, SP0 and SP1). Records ESR, ELR, FAR, LR, SP, FP, SPSR and a marker in the
 * vector slot 0x180 above (SError, never taken this early) and spins there.
 */
	.globl trapvec_tmpl, trapvec_tmpl_end
	.balign	4
trapvec_tmpl:
	adr	x9, trapvec_tmpl + 0x180
	mrs	x16, esr_el1
	str	x16, [x9]
	mrs	x16, elr_el1
	str	x16, [x9, #8]
	mrs	x16, far_el1
	str	x16, [x9, #16]
	str	x30, [x9, #24]
	mov	x16, sp
	str	x16, [x9, #32]
	str	x29, [x9, #40]
	mrs	x16, spsr_el1
	str	x16, [x9, #48]
	mrs	x16, cpacr_el1
	str	x16, [x9, #64]
	mrs	x16, cntvct_el0
	str	x16, [x9, #72]
	mov	x16, #0x5452
	str	x16, [x9, #56]
	dsb	sy
8:	wfe
	b	8b
trapvec_tmpl_end:

/*
 * Exceptions: every slot saves x0-x30 and calls avfboot_exception(slot, regs),
 * which prints them and powers the VM off.
 */
.macro vent slot
	.balign	0x80
	sub	sp, sp, #(32 * 8)
	stp	x0, x1, [sp, #0]
	mov	x0, #\slot
	b	exc_common
.endm

	.balign	0x800
vectors:
	vent 0
	vent 1
	vent 2
	vent 3
	vent 4
	vent 5
	vent 6
	vent 7
	vent 8
	vent 9
	vent 10
	vent 11
	vent 12
	vent 13
	vent 14
	vent 15

exc_common:
	stp	x2, x3, [sp, #16]
	stp	x4, x5, [sp, #32]
	stp	x6, x7, [sp, #48]
	stp	x8, x9, [sp, #64]
	stp	x10, x11, [sp, #80]
	stp	x12, x13, [sp, #96]
	stp	x14, x15, [sp, #112]
	stp	x16, x17, [sp, #128]
	stp	x18, x19, [sp, #144]
	stp	x20, x21, [sp, #160]
	stp	x22, x23, [sp, #176]
	stp	x24, x25, [sp, #192]
	stp	x26, x27, [sp, #208]
	stp	x28, x29, [sp, #224]
	str	x30, [sp, #240]
	mov	x1, sp
	bl	avfboot_exception
6:	wfe
	b	6b
