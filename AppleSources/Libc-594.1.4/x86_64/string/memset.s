/*
 * Copyright (c) 2005 Apple Computer, Inc. All rights reserved.
 *
 * @APPLE_LICENSE_HEADER_START@
 *
 * The contents of this file constitute Original Code as defined in and
 * are subject to the Apple Public Source License Version 1.1 (the
 * "License").  You may not use this file except in compliance with the
 * License.  Please obtain a copy of the License at
 * http://www.apple.com/publicsource and read it before using this file.
 *
 * This Original Code and all software distributed under the License are
 * distributed on an "AS IS" basis, WITHOUT WARRANTY OF ANY KIND, EITHER
 * EXPRESS OR IMPLIED, AND APPLE HEREBY DISCLAIMS ALL SUCH WARRANTIES,
 * INCLUDING WITHOUT LIMITATION, ANY WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE OR NON-INFRINGEMENT.  Please see the
 * License for the specific language governing rights and limitations
 * under the License.
 *
 * @APPLE_LICENSE_HEADER_END@
 */

#include <machine/cpu_capabilities.h>
 

/* This file contains the following functions:
 *
 *	void *memset(void *b, int c, size_t len);
 *	void memset_pattern4(void *b, const void *c4, size_t len);
 *	void memset_pattern8(void *b, const void *c8, size_t len);
 *	void memset_pattern16(void *b, const void *c16, size_t len);
 *
 * Calls of memset() with c==0 are routed to the bzero() routine.  Most of the
 * others go to _COMM_PAGE_MEMSET_PATTERN, which is entered as follows:
 *	%rdi = ptr to memory to set (aligned)
 *	%edx = length (which can be short, though we bias in favor of long operands)
 *	%xmm0 = the pattern to store
 * Return conditions:
 *	%eax, %edi, %esi, %ecx, and %edx all trashed
 *
 * NB: we avoid "stos" family of instructions (stosl, stosb), as they are very slow
 * on P4s and probably other processors.
 */
 
 #define kShort	255			// for nonzero memset(), too short for commpage
 
 
	.text
	.globl	_memset
	.align	2
_memset:				// void *memset(void *b, int c, size_t len);
	andl	$0xFF,%esi		// (c==0) ?
	jnz		LNonzero		// not a bzero
	
	movq	$(_COMM_PAGE_BZERO),%rax// map memset(p,0,n) into bzero(p,n)
	movq	%rdx,%rsi		// put count where bzero() expects it
	jmp		*%rax			// enter commpage


	// Handle memset of a nonzero value.
	
LNonzero:
	movq	%rdi,%r8		// preserve the original pointer so we can return it
	movl	%esi,%eax		// replicate byte in %esi into all four bytes
	shll	$8,%esi
	orl		%esi,%eax
	movl	%eax,%esi
	shll	$16,%esi
	orl		%esi,%eax		// now %eax has "c" in all 4 bytes
	cmpq	$(kShort),%rdx		// is operand too short for SSE?
	ja		LCallCommpage		// no
	
// Nonzero memset() too short to call commpage.
//	%eax = replicated 4-byte pattern
//	%rdi = ptr
//	%edx = length (<= kShort)
	
	cmpl	$16,%edx		// long enough to word align?
	jge	3f			// yes
	test	%edx,%edx		// length==0?
	jz	6f
1:
	movb	%al,(%rdi)		// pack in a byte
	addq	$1,%rdi
	subl	$1,%edx
	jnz	1b
	jmp	6f
2:
	movb	%al,(%rdi)		// pack in a byte
	addq	$1,%rdi
	subl	$1,%edx
3:
	test	$3,%edi			// is ptr doubleword aligned?
	jnz	2b			// no
	movl	%edx,%ecx		// copy length
	shrl	$2,%edx			// #doublewords to store
4:      
	movl	%eax,(%rdi)		// store aligned doubleword
	addq	$4,%rdi
	subl	$1,%edx
	jnz	4b
	andl	$3,%ecx			// any leftover bytes?
	jz	6f			// no
5:
	movb	%al,(%rdi)		// pack in a byte
	addq	$1,%rdi
	subl	$1,%ecx
	jnz	5b
6:
	movq	%r8,%rax		// get return value (ie, original ptr)
	ret
	
// Nonzero memset() is long enough to call commpage.
//	%eax = replicated 4-byte pattern
//	%rdi = ptr
//	%rdx = length (> kShort)
	
LCallCommpage:
	movd	%eax,%xmm0		// move %eax to low 4 bytes of %xmm0
	pshufd	$(0x00),%xmm0,%xmm0	// replicate across the vector
	movq	%rdi,%rcx		// copy dest ptr
	negl	%ecx
	andl	$15,%ecx		// get #bytes to align ptr
	jz	2f			// skip if already aligned
	subq	%rcx,%rdx		// decrement length
1:
	movb	%al,(%rdi)		// pack in a byte
	addq	$1,%rdi
	subl	$1,%ecx
	jnz	1b
2:					// ptr aligned, length long enough to justify
	movq	$(_COMM_PAGE_MEMSET_PATTERN),%rax
	call	*%rax			// call commpage to do the heavy lifting
	movq	%r8,%rax		// get return value (ie, original ptr)
	ret


// Handle memset of a 16-byte pattern.
	
	.globl	_memset_pattern16
	.align	2, 0x90
_memset_pattern16:			// void memset_pattern16(void *b, const void *c16, size_t len);
	movdqu	(%rsi),%xmm0		// load the pattern
	jmp	LAlignPtr


// Handle memset of an 8-byte pattern.
	
	.globl	_memset_pattern8
	.align	2, 0x90
_memset_pattern8:			// void memset_pattern8(void *b, const void *c8, size_t len);
	movq	(%rsi),%xmm0		// load pattern into low 8 bytes
	punpcklqdq %xmm0,%xmm0		// replicate into all 16
	jmp	LAlignPtr

// Handle memset of a 4-byte pattern.
	
	.globl	_memset_pattern4
	.align	2, 0x90
_memset_pattern4:			// void memset_pattern4(void *b, const void *c4, size_t len);
	movd	(%rsi),%xmm0		// load pattern into low 4 bytes
	pshufd	$(0x00),%xmm0,%xmm0	// replicate the 4 bytes across the vector


// Align ptr if necessary.  We must rotate the pattern right for each byte we
// store while aligning the ptr.  Since there is no rotate instruction in SSE3,
// we have to synthesize the rotates.
//	%rdi = ptr
//	%rdx = length
//	%xmm0 = pattern
	
LAlignPtr:				// NB: can drop down to here!
	cmpq	$100,%rdx		// long enough to bother aligning ptr?
	movq	%rdi,%rcx		// copy ptr
	jb	LReady			// not long enough
	negl	%ecx
	andl	$15,%ecx		// get #bytes to align ptr
	jz	LReady			// already aligned
	subq	%rcx,%rdx		// adjust length
	
	test	$1,%cl			// 1-byte store required?
	movd	%xmm0,%eax		// get 4 low bytes in %eax
	jz	2f			// no
	movdqa	%xmm0,%xmm1		// copy pattern so we can shift in both directions
	movb	%al,(%rdi)		// pack in the low-order byte
	psrldq	$1,%xmm0		// shift pattern right 1 byte
	addq	$1,%rdi
	pslldq	$15,%xmm1		// shift pattern left 15 bytes
	shrl	$8,%eax			// in case 2-byte store is required
	por	%xmm1,%xmm0		// complete right rotate of pattern by 1 byte
2:
	test	$2,%cl			// 2-byte store required?
	jz	4f			// no
	psrldq	$2,%xmm0		// shift pattern down 2 bytes
	movw	%ax,(%rdi)		// pack in next two bytes
	pinsrw	$7,%eax,%xmm0		// insert low word of %eax into high word of %xmm0
	addq	$2,%rdi			// adjust ptr
4:
	test	$4,%cl			// 4-byte store required?
	jz	8f			// no
	movd	%xmm0,(%rdi)		// store low 4 bytes of %xmm0
	pshufd	$(0x39),%xmm0,%xmm0	// rotate %xmm0 right 4 bytes (mask == 00 11 10 01)
	addq	$4,%rdi			// adjust ptr
8:
	test	$8,%cl			// 8-byte store required?
	jz	LReady			// no
	movq	%xmm0,(%rdi)		// store low 8 bytes of %xmm0
	pshufd	$(0x4e),%xmm0,%xmm0	// rotate %xmm0 right 8 bytes (mask == 01 00 11 10)
	addq	$8,%rdi			// adjust ptr
	
// Ptr is aligned if practical, we're ready to call commpage to do the heavy lifting.

LReady:
	movq	$(_COMM_PAGE_MEMSET_PATTERN),%rax
	call	*%rax			// call commpage to do the heavy lifting
	ret
