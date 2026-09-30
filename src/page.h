/*
 * page.h - page console output a screenful at a time
 */
#ifndef PAGE_H
#define PAGE_H

/* Page stdout when input and output are one console; see page.c. */
void page_begin(void);
void page_end(void);
/* printf that keeps the page accounting; one newline in fmt = one line. */
void pout(const char *fmt, ...);

#endif
