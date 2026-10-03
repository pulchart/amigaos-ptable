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
static int page_cols;           /* window width, 0 = unknown */
static char page_line[512];     /* the line being built, written whole */
static int page_len;
static int page_cont;           /* page_line continues a line already partly out */
static int page_carry;          /* its characters already out, width unknown or wide */

static void page_emit(int whole);
static int page_stop;           /* the reader asked to stop */
static char page_erase[sizeof(PAGE_TEXT) + 1];      /* CR, blanks, CR */

/* Ask the console how tall and wide its window is. RAW mode must already
 * be set. WINDOW STATUS REQUEST is answered by a WINDOW BOUNDS REPORT,
 * CSI <p1>;<p2>;<p3>;<p4> SP r: the third field is the height, the fourth
 * the width.
 */
static int page_query_rows(void)
{
    int fields = 0, num = 0, rows = 0, guard = 40;
    UBYTE c;

    Write(page_out, "\033[ q", 4);
    while (guard--) {
        if (!WaitForChar(page_in, 200000)) return 0;   /* console stayed silent */
        if (Read(page_in, &c, 1) != 1) return 0;
        if (c == 'r') {
            if (fields < 3) return 0;                   /* too short to trust */
            page_cols = num;
            return rows;
        }
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

    page_rows = page_left = page_stop = page_cols = page_len = page_cont = 0;
    page_carry = 0;
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
    if (page_cols && page_cols < (int)sizeof(PAGE_TEXT))
        rows = 0;                       /* the prompt would wrap: do not pause */
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
    if (page_len && !page_stop)         /* an unfinished last line */
        page_emit(1);
    page_len = page_cont = page_carry = 0;
    if (!page_rows) return;
    page_rows = 0;
    SetMode(page_in, 0);                /* always hand the shell back cooked */
}

/* Show the prompt and wait for a key. Returns 0 when the reader asked to
 * stop. */
static int page_wait(void)
{
    UBYTE key = '\n';

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

/* Screen rows that n characters fill. */
static int page_span(int n)
{
    return n <= 0 ? 0 : (n + page_cols - 1) / page_cols;
}

/* Write the line built so far. A line wider than the window wraps onto
 * several rows; when they do not fit on what is left of the page, pause
 * first, so nothing scrolls away unread. A line taller than a whole page
 * goes out a page at a time. When the buffer fills before the line ends
 * (whole = 0), only complete rows go out and the rest waits for the line,
 * so the buffer always starts a row.
 */
static void page_emit(int whole)
{
    int start = 0, end = page_len, i, vis = 0, rows, room;

    for (i = 0; i < page_len; i++)
        if (page_line[i] != '\r' && page_line[i] != '\n') vis++;
    if (page_cols <= 0) {
        /* width unknown: the line is one row, charged by its first piece */
        rows = page_cont ? 0 : 1;
        if (page_rows && rows > page_left && page_left < page_rows && !page_wait()) {
            page_len = 0;
            return;
        }
        fwrite(page_line, 1, page_len, stdout);
        if (page_rows) page_left -= rows;
        page_len = 0;
        page_cont = !whole;
        return;
    }
    if (page_cols >= (int)sizeof(page_line)) {
        /* No row fits the buffer: write each piece as it comes, charging the
         * rows it starts, and fill the page before a pause. page_carry holds
         * the characters of this line already out. */
        for (;;) {
            for (i = start, vis = 0; i < page_len; i++)
                if (page_line[i] != '\r' && page_line[i] != '\n') vis++;
            rows = page_span(page_carry + vis) - page_span(page_carry);
            if (!page_cont && !page_carry && !rows) rows = 1;   /* an empty line */
            if (!page_rows || rows <= page_left) {
                fwrite(page_line + start, 1, page_len - start, stdout);
                if (page_rows) page_left -= rows;
                page_carry += vis;
                break;
            }
            room = page_span(page_carry) * page_cols - page_carry
                 + page_left * page_cols;               /* fits on this page */
            if (!page_cont && !page_carry && page_left < page_rows)
                room = 0;               /* a new line starts on a fresh page */
            if (room <= 0) {
                if (!page_wait()) break;
                continue;
            }
            fwrite(page_line + start, 1, room, stdout);
            start += room;
            page_carry += room;
            page_left = 0;              /* full: the rest waits for a key */
            page_cont = 1;
        }
        if (whole || page_stop) page_carry = 0;
        page_len = 0;
        page_cont = !whole;
        return;
    }
    if (!whole) {
        end = page_len - vis % page_cols;               /* whole rows only */
        if (end <= 0) end = page_len;
    }
    for (;;) {
        for (i = start, vis = 0; i < end; i++)
            if (page_line[i] != '\r' && page_line[i] != '\n') vis++;
        rows = page_span(vis);
        if (!whole)
            rows = vis / page_cols;
        else if (!rows && !page_cont)
            rows = 1;                   /* an empty line */
        if (page_rows && rows > page_left && page_left < page_rows && !page_wait())
            break;
        if (!page_rows || rows <= page_left) {
            fwrite(page_line + start, 1, end - start, stdout);
            if (page_rows) page_left -= rows;
            break;
        }
        room = page_left * page_cols;   /* fills the rows that are left */
        fwrite(page_line + start, 1, room, stdout);
        start += room;
        page_left = 0;                  /* full: the rest waits for a key */
    }
    if (page_stop) end = page_len;
    memmove(page_line, page_line + end, page_len - end);
    page_len -= end;
    page_cont = !whole;
}

/* printf that keeps the page accounting. Output is held until its line is
 * complete, so the rows it needs are known before it is written.
 */
void pout(const char *fmt, ...)
{
    static char buf[512];
    va_list ap;
    const char *c = fmt;

    if (page_stop) return;
    if (strchr(fmt, '%')) {             /* plain text needs no buffer */
        va_start(ap, fmt);
        vsnprintf(buf, sizeof(buf), fmt, ap);
        va_end(ap);
        c = buf;
    }
    for (; *c && !page_stop; c++) {
        page_line[page_len++] = *c;
        if (*c == '\n' || page_len == sizeof(page_line))
            page_emit(*c == '\n');
    }
}
