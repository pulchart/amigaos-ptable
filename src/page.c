/*
 * page.c - page console output a screenful at a time
 */

#include <exec/types.h>
#include <dos/dos.h>
#include <dos/dosextens.h>
#include <proto/dos.h>

#include <stdarg.h>
#include <stdio.h>
#include <string.h>

#include "page.h"

/* --- console pager -------------------------------------------------
 *
 * One screenful at a time: any key continues, Q stops the rest of the
 * report. Paging is on only when input and output are the same console,
 * and only when that console reports a plausible height; a redirected
 * or silent stream scrolls as before.
 */
#define PAGE_TEXT "-- more -- (any key, Q quits)"
/* italic and reversed on, then off again; other attributes are kept */
#define PAGE_PROMPT "\033[3;7m" PAGE_TEXT "\033[23;27m"

static BPTR page_in, page_out;
static int page_rows;           /* usable lines per page, 0 = no paging */
static int page_left;
static int page_stop;           /* the reader asked to stop */
static char page_erase[sizeof(PAGE_TEXT) + 1];      /* CR, blanks, CR */

/* Ask the console how tall its window is. RAW mode must already be set.
 * WINDOW STATUS REQUEST is answered by a WINDOW BOUNDS REPORT,
 * CSI <p1>;<p2>;<p3>;<p4> SP r, whose third field is the height.
 */
static int page_query_rows(void)
{
    int fields = 0, num = 0, rows = 0, guard = 40;
    UBYTE c;

    Write(page_out, "\033[ q", 4);
    while (guard--) {
        if (!WaitForChar(page_in, 200000)) return 0;   /* console stayed silent */
        if (Read(page_in, &c, 1) != 1) return 0;
        if (c == 'r') return (fields >= 3) ? rows : 0; /* too short to trust */
        if (c == ';') {
            if (++fields == 3) rows = num;
            num = 0;
            continue;
        }
        if (c < '0' || c > '9') continue;
        if (num < 1000) num = num * 10 + (c - '0');    /* absurd: stop adding */
    }
    return 0;
}

void page_begin(void)
{
    struct FileHandle *in, *out;
    int rows;

    page_rows = page_left = page_stop = 0;
    page_in = Input();
    page_out = Output();
    if (!page_in || !page_out) return;
    if (!IsInteractive(page_in) || !IsInteractive(page_out)) return;

    /* The query is written to the output and answered on the input, so both
     * must be the same handler. Equal fh_Type means one console; a redirected
     * ">SER:" is a different port and gets neither the query nor a pause.
     */
    in = (struct FileHandle *)BADDR(page_in);
    out = (struct FileHandle *)BADDR(page_out);
    if (in->fh_Type != out->fh_Type) return;

    SetMode(page_in, 1);                /* RAW for the query and every keypress */
    rows = page_query_rows() - 1;       /* the prompt needs a line of its own */
    if (rows < 4 || rows > 200) {       /* implausible height, do not guess */
        SetMode(page_in, 0);
        return;
    }
    page_rows = page_left = rows;

    page_erase[0] = '\r';
    memset(page_erase + 1, ' ', sizeof(PAGE_TEXT) - 1);
    page_erase[sizeof(PAGE_TEXT)] = '\r';
}

void page_end(void)
{
    if (!page_rows) return;
    page_rows = 0;
    SetMode(page_in, 0);                /* always hand the shell back cooked */
}

/* Call after writing one line. Returns 0 when the reader asked to stop. */
static int page_line(void)
{
    UBYTE key = '\n';

    if (!page_rows) return 1;
    if (--page_left > 0) return 1;

    fflush(stdout);                     /* the prompt bypasses stdio */
    Write(page_out, PAGE_PROMPT, sizeof(PAGE_PROMPT) - 1);
    if (Read(page_in, &key, 1) != 1) key = '\n';
    Write(page_out, page_erase, sizeof(page_erase));
    page_left = page_rows;              /* a fresh page */
    if ((key & 0xdf) == 'Q') {          /* fold case */
        page_stop = 1;
        return 0;
    }
    return 1;
}

/* printf that keeps the page accounting. No format here spans two lines,
 * so one newline in the format is one line on screen.
 */
void pout(const char *fmt, ...)
{
    va_list ap;
    const char *c;

    if (page_stop) return;
    va_start(ap, fmt);
    vprintf(fmt, ap);
    va_end(ap);
    for (c = fmt; *c; c++)
        if (*c == '\n' && !page_line()) return;
}
