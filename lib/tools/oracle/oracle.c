// oracle.c
//
// A machine-readable host for the real teletype language core, used to
// generate golden fixtures for the lua port. It links the unmodified sources
// from ../../teletype/src and implements teletype_io.h by logging every call,
// so a fixture captures both the returned value and the side effects.
//
// Modes:
//   oracle ops              dump the op and mod tables (name/params/returns/set)
//   oracle parse   < lines  per line: parse + validate + print_command
//   oracle process < lines  as above, then execute against one persistent scene
//   oracle tables           dump the numeric lookup tables
//
// Output is TSV with a leading record type, one record per line. Fields never
// contain tabs; io log entries are packed into a single space-separated field.

#include <ctype.h>
#include <inttypes.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "command.h"
#include "helpers.h"
#include "ops/op.h"
#include "ops/op_enum.h"
#include "scale.h"
#include "state.h"
#include "table.h"
#include "teletype.h"
#include "teletype_io.h"
#include "music.h"
#include "random.h"
#include "drum_helpers.h"
#include "euclidean/euclidean.h"
#include "scene_serialization.h"
#include "serializer.h"

// ---------------------------------------------------------------- io logging

#define IOLOG_MAX 8192
static char iolog[IOLOG_MAX];
static size_t iolog_len = 0;
static uint32_t fake_ticks = 0;

static void iolog_reset(void) {
    iolog[0] = 0;
    iolog_len = 0;
}

static void iologf(const char *fmt, ...) {
    va_list args;
    va_start(args, fmt);
    if (iolog_len && iolog_len < IOLOG_MAX - 1) iolog[iolog_len++] = ' ';
    int n = vsnprintf(iolog + iolog_len, IOLOG_MAX - iolog_len, fmt, args);
    if (n > 0) iolog_len += (size_t)n;
    if (iolog_len >= IOLOG_MAX) iolog_len = IOLOG_MAX - 1;
    va_end(args);
}

uint32_t tele_get_ticks(void) { return fake_ticks; }
void tele_metro_updated(void) { iologf("metro_updated"); }
void tele_metro_reset(void) { iologf("metro_reset"); }
void tele_tr(uint8_t i, int16_t v) { iologf("tr(%u,%d)", i, v); }
void tele_tr_pulse(uint8_t i, int16_t t) { iologf("tr_pulse(%u,%d)", i, t); }
void tele_tr_pulse_clear(uint8_t i) { iologf("tr_pulse_clear(%u)", i); }
void tele_tr_pulse_time(uint8_t i, int16_t t) {
    iologf("tr_pulse_time(%u,%d)", i, t);
}
void tele_cv(uint8_t i, int16_t v, uint8_t s) { iologf("cv(%u,%d,%u)", i, v, s); }
void tele_cv_slew(uint8_t i, int16_t v) { iologf("cv_slew(%u,%d)", i, v); }
uint16_t tele_get_cv(uint8_t i) { iologf("get_cv(%u)", i); return 0; }
void tele_cv_cal(uint8_t n, int32_t b, int32_t m) {
    iologf("cv_cal(%u,%d,%d)", n, b, m);
}
void tele_cv_off(uint8_t i, int16_t v) { iologf("cv_off(%u,%d)", i, v); }
void tele_update_adc(uint8_t f) { iologf("update_adc(%u)", f); }
void tele_has_delays(bool b) { iologf("has_delays(%d)", b ? 1 : 0); }
void tele_has_stack(bool b) { iologf("has_stack(%d)", b ? 1 : 0); }
void tele_ii_tx(uint8_t addr, uint8_t *data, uint8_t l) {
    // built in one go: iologf separates each call with a space, which would
    // otherwise scatter spaces through the byte list
    char buf[256];
    int n = snprintf(buf, sizeof(buf), "ii_tx(%u,%u", addr, l);
    for (size_t i = 0; i < l && n < (int)sizeof(buf) - 8; i++) {
        n += snprintf(buf + n, sizeof(buf) - n, ",%u", data[i]);
    }
    snprintf(buf + n, sizeof(buf) - n, ")");
    iologf("%s", buf);
}
void tele_ii_rx(uint8_t addr, uint8_t *data, uint8_t l) {
    iologf("ii_rx(%u,%u)", addr, l);
    for (size_t i = 0; i < l; i++) data[i] = 0;
}
void tele_scene(uint8_t i, uint8_t g, uint8_t p) {
    iologf("scene(%u,%u,%u)", i, g, p);
}
void tele_pattern_updated(void) { iologf("pattern_updated"); }
void tele_vars_updated(void) {}
void tele_kill(void) { iologf("kill"); }
void tele_mute(void) { iologf("mute"); }
bool tele_get_input_state(uint8_t n) { iologf("input_state(%u)", n); return false; }
void tele_save_calibration(void) {}
void grid_key_press(uint8_t x, uint8_t y, uint8_t z) {
    iologf("grid_key(%u,%u,%u)", x, y, z);
}
void device_flip(void) { iologf("device_flip"); }
void set_live_submode(uint8_t s) { iologf("live_submode(%u)", s); }
void select_dash_screen(uint8_t s) { iologf("dash_screen(%u)", s); }
void print_dashboard_value(uint8_t i, int16_t v) { iologf("dash_set(%u,%d)", i, v); }
int16_t get_dashboard_value(uint8_t i) { iologf("dash_get(%u)", i); return 0; }
void reset_midi_counter(void) { iologf("reset_midi_counter"); }

// ------------------------------------------------------------------- helpers

static const char *tag_name(tele_word_t t) {
    switch (t) {
        case NUMBER: return "NUMBER";
        case XNUMBER: return "XNUMBER";
        case BNUMBER: return "BNUMBER";
        case RNUMBER: return "RNUMBER";
        case OP: return "OP";
        case MOD: return "MOD";
        case PRE_SEP: return "PRE_SEP";
        case SUB_SEP: return "SUB_SEP";
    }
    return "?";
}

// tele_error() returns human strings; fixtures want a stable symbolic name.
static const char *err_name(error_t e) {
    static const char *names[] = {
        "E_OK",           "E_PARSE",          "E_LENGTH",
        "E_NEED_PARAMS",  "E_EXTRA_PARAMS",   "E_NO_MOD_HERE",
        "E_MANY_PRE_SEP", "E_NEED_PRE_SEP",   "E_PLACE_PRE_SEP",
        "E_NO_SUB_SEP_IN_PRE", "E_NOT_LEFT",  "E_NEED_SPACE_PRE_SEP",
        "E_NEED_SPACE_SUB_SEP"
    };
    if (e < 0 || e >= (int)(sizeof(names) / sizeof(names[0]))) return "E_?";
    return names[e];
}

static void strip_newline(char *s) {
    size_t n = strlen(s);
    while (n && (s[n - 1] == '\n' || s[n - 1] == '\r')) s[--n] = 0;
}

static void upcase(char *s) {
    for (; *s; s++) *s = toupper((unsigned char)*s);
}

// Emit the parsed word array as "TAG:VALUE,TAG:VALUE,..."
static void print_words(const tele_command_t *c) {
    for (size_t i = 0; i < c->length; i++) {
        if (i) printf(",");
        // for OP/MOD emit the name, so fixtures stay readable and are not
        // coupled to op_enum.h ordering
        if (c->data[i].tag == OP)
            printf("OP:%s", tele_ops[c->data[i].value]->name);
        else if (c->data[i].tag == MOD)
            printf("MOD:%s", tele_mods[c->data[i].value]->name);
        else
            printf("%s:%d", tag_name(c->data[i].tag), c->data[i].value);
    }
}

// --------------------------------------------------------------------- modes

static void dump_ops(void) {
    for (size_t i = 0; i < E_OP__LENGTH; i++) {
        const tele_op_t *op = tele_ops[i];
        printf("op\t%s\t%u\t%d\t%d\n", op->name, op->params,
               op->returns ? 1 : 0, op->set != NULL ? 1 : 0);
    }
    for (size_t i = 0; i < E_MOD__LENGTH; i++) {
        const tele_mod_t *m = tele_mods[i];
        printf("mod\t%s\t%u\n", m->name, m->params);
    }
}

static void dump_tables(void) {
    for (int i = 0; i < 11; i++) printf("table_v\t%d\t%d\n", i, table_v[i]);
    for (int i = 0; i < 100; i++) printf("table_vv\t%d\t%d\n", i, table_vv[i]);
    for (int i = 0; i < 76; i++) printf("table_hzv\t%d\t%d\n", i, table_hzv[i]);
    for (int i = 0; i < 256; i++) printf("table_exp\t%d\t%d\n", i, table_exp[i]);
    for (int i = 0; i < 32; i++) printf("table_nr\t%d\t%d\n", i, table_nr[i]);
    for (int i = 0; i < ET_SIZE; i++) printf("table_n\t%d\t%d\n", i, ET[i]);
    for (int i = 0; i < 9; i++)
        for (int j = 0; j < 7; j++)
            printf("table_n_s\t%d,%d\t%d\n", i, j, table_n_s[i][j]);
    for (int i = 0; i < 13; i++)
        for (int j = 0; j < 4; j++)
            printf("table_n_c\t%d,%d\t%d\n", i, j, table_n_c[i][j]);
    for (int i = 0; i < 9; i++)
        for (int j = 0; j < 7; j++)
            printf("table_n_cs\t%d,%d\t%d\n", i, j, table_n_cs[i][j]);
    for (int i = 0; i < nb_nbx_scale_presets; i++)
        printf("table_n_b\t%d\t%d\n", i, table_n_b[i]);
    for (int i = 0; i < 7; i++)
        for (int j = 0; j < 7; j++)
            printf("scale_int\t%d,%d\t%d\n", i, j, SCALE_INT[i][j]);

    // The drum tables are bit-packed MSB-first, one pattern per row. Emitting
    // each row as a single integer keeps the fixture compact and lets the lua
    // side index bits arithmetically instead of carrying a byte array.
    for (int p = 0; p < drum_ops_pattern_len; p++) {
        uint32_t v = 0;
        for (int b = 0; b < 3; b++) v = (v << 8) | (uint8_t)table_t_r_e[p][b];
        printf("table_t_r_e\t%d\t%u\n", p, v);
    }
#define DUMP_DRUM(name)                                                    \
    for (int p = 0; p < drum_ops_pattern_len; p++) {                       \
        uint32_t v = 0;                                                    \
        for (int b = 0; b < 2; b++) v = (v << 8) | (uint8_t)name[p][b];    \
        printf(#name "\t%d\t%u\n", p, v);                                  \
    }
    DUMP_DRUM(table_dr_bd)
    DUMP_DRUM(table_dr_sd)
    DUMP_DRUM(table_dr_ch)
    DUMP_DRUM(table_dr_oh)
#undef DUMP_DRUM

    for (int p = 0; p < 20; p++)
        for (int s = 0; s < 16; s++)
            printf("table_vel_helper\t%d,%d\t%u\n", p, s, table_vel_helper[p][s]);

    // Euclidean patterns live in 32 separate arrays of differing shape in
    // libavr32; resolving them here to one 32-bit mask per (fill, len) avoids
    // reproducing that layout.
    for (int fill = 0; fill <= 32; fill++) {
        for (int len = 0; len <= 32; len++) {
            uint32_t mask = 0;
            for (int step = 0; step < 32; step++) {
                if (euclidean(fill, len, step)) mask |= (1u << step);
            }
            printf("euclidean\t%d,%d\t%u\n", fill, len, mask);
        }
    }
}

// parse + validate + unparse. one record per input line.
// fields: "line" <input> <parse_err> <parse_msg> <words> <separator>
//                <validate_err> <validate_msg> <printed>
static void mode_parse(void) {
    char in[512];
    while (fgets(in, sizeof(in), stdin)) {
        strip_newline(in);
        if (in[0] == '#' || in[0] == 0) continue;  // fixture comments
        char work[512];
        strcpy(work, in);
        upcase(work);

        tele_command_t cmd;
        char msg[TELE_ERROR_MSG_LENGTH];
        error_t status = parse(work, &cmd, msg);

        printf("line\t%s\t%s\t%s\t", in, err_name(status), msg);
        if (status == E_OK) {
            print_words(&cmd);
            printf("\t%d\t", cmd.separator);
            char vmsg[TELE_ERROR_MSG_LENGTH];
            error_t vstatus = validate(&cmd, vmsg);
            printf("%s\t%s\t", err_name(vstatus), vmsg);
            if (vstatus == E_OK) {
                char out[256];
                print_command(&cmd, out);
                printf("%s", out);
            }
        }
        else {
            printf("\t\t\t\t");
        }
        printf("\n");
    }
}

// execute each line against a single persistent scene, dumping the result and
// the io side effects. this is the phase 2 oracle.
static void mode_process(void) {
    char in[512];
    scene_state_t ss;
    ss_init(&ss);

    while (fgets(in, sizeof(in), stdin)) {
        strip_newline(in);
        if (in[0] == '#' || in[0] == 0) continue;

        // "!script N LINE CMD" installs a line into script N (0-based; 8 is
        // the metro script, 9 is init). Needed to exercise anything that
        // depends on a script context: SCRIPT, $F/$L/$S, EVERY/SKIP, DEL.
        if (strncmp(in, "!script ", 8) == 0) {
            int n, line;
            char body[512];
            if (sscanf(in + 8, "%d %d %511[^\n]", &n, &line, body) == 3) {
                char work2[512];
                strcpy(work2, body);
                upcase(work2);
                tele_command_t c;
                char m[TELE_ERROR_MSG_LENGTH];
                if (parse(work2, &c, m) == E_OK && validate(&c, m) == E_OK) {
                    ss_overwrite_script_command(&ss, n, line, &c);
                    printf("script\t%d,%d\t%s\t\n", n, line, body);
                }
                else {
                    printf("script\t%d,%d\t%s\tBAD\n", n, line, body);
                }
            }
            continue;
        }
        // "!clear N" empties a script
        if (strncmp(in, "!clear ", 7) == 0) {
            ss_clear_script(&ss, atoi(in + 7));
            printf("clear\t%s\t\n", in + 7);
            continue;
        }
        // "!run N" runs a whole script in a fresh execution context
        if (strncmp(in, "!run ", 5) == 0) {
            iolog_reset();
            run_script(&ss, atoi(in + 5));
            printf("runscript\t%s\t%s\n", in + 5, iolog);
            continue;
        }
        // "!tick N" advances the delay clock; "!ticks N" sets the ms counter
        if (strncmp(in, "!tick ", 6) == 0) {
            int n = atoi(in + 6);
            iolog_reset();
            tele_tick(&ss, (uint8_t)n);
            printf("tick\t%d\t%s\n", n, iolog);
            continue;
        }
        if (strncmp(in, "!ticks ", 7) == 0) {
            fake_ticks = (uint32_t)atoi(in + 7);
            printf("ticks\t%u\t\n", fake_ticks);
            continue;
        }

        char work[512];
        strcpy(work, in);
        upcase(work);

        tele_command_t cmd;
        char msg[TELE_ERROR_MSG_LENGTH];
        error_t status = parse(work, &cmd, msg);
        if (status != E_OK) {
            printf("err\t%s\t%s\t%s\n", in, err_name(status), msg);
            continue;
        }
        status = validate(&cmd, msg);
        if (status != E_OK) {
            printf("err\t%s\t%s\t%s\n", in, err_name(status), msg);
            continue;
        }

        exec_state_t es;
        es_init(&es);
        es_push(&es);
        iolog_reset();
        process_result_t r = process_command(&ss, &es, &cmd);
        printf("run\t%s\t%d\t%d\t%s\n", in, r.has_value ? 1 : 0,
               r.has_value ? r.value : 0, iolog);
    }

    // final scene snapshot, so state-mutating ops are covered too
    printf("var\tA\t%d\n", ss.variables.a);
    printf("var\tB\t%d\n", ss.variables.b);
    printf("var\tC\t%d\n", ss.variables.c);
    printf("var\tD\t%d\n", ss.variables.d);
    printf("var\tX\t%d\n", ss.variables.x);
    printf("var\tY\t%d\n", ss.variables.y);
    printf("var\tZ\t%d\n", ss.variables.z);
    printf("var\tT\t%d\n", ss.variables.t);
    printf("var\tO\t%d\n", ss.variables.o);
    printf("var\tDRUNK\t%d\n", ss.variables.drunk);
    printf("var\tQ_N\t%d\n", ss.variables.q_n);
    printf("var\tP_N\t%d\n", ss.variables.p_n);
    printf("var\tM\t%d\n", ss.variables.m);
    for (int i = 0; i < CV_COUNT; i++)
        printf("cv\t%d\t%d\n", i, ss.variables.cv[i]);
    for (int i = 0; i < TR_COUNT; i++)
        printf("tr\t%d\t%d\n", i, ss.variables.tr[i]);
    for (int p = 0; p < PATTERN_COUNT; p++) {
        printf("pat\t%d\tl=%d,w=%d,s=%d,e=%d,i=%d\n", p,
               ss.patterns[p].len, ss.patterns[p].wrap, ss.patterns[p].start,
               ss.patterns[p].end, ss.patterns[p].idx);
        for (int i = 0; i < PATTERN_LENGTH; i++)
            printf("patv\t%d,%d\t%d\n", p, i, ss.patterns[p].val[i]);
    }
    for (int i = 0; i < Q_LENGTH; i++)
        printf("q\t%d\t%d\n", i, ss.variables.q[i]);
}

// the MWC generator from libavr32, so the lua port can be checked for exact
// sequence equivalence -- teletype exposes six seedable generators and a
// seeded scene is expected to replay identically.
static void dump_random(void) {
    static const int32_t seeds[] = { 0, 1, 2, 42, -1, 12345, 32767, -32768 };
    for (size_t s = 0; s < sizeof(seeds) / sizeof(seeds[0]); s++) {
        random_state_t r;
        random_seed(&r, (uint32_t)seeds[s]);
        for (int i = 0; i < 32; i++) {
            printf("rand\t%d\t%d\t%u\n", seeds[s], i, random_next(&r));
        }
    }
}

// ------------------------------------------------------------------- scenes
// Load a scene .txt through the real deserializer, then write it back out
// through the real serializer. Comparing the output byte for byte against the
// lua port is the strongest possible check on the file format.

static FILE *scene_in;
static int scene_peek = EOF;
static bool scene_eof_flag = false;

static uint16_t scene_read_char(void *NOTUSED_data) {
    (void)NOTUSED_data;
    int c = scene_peek != EOF ? scene_peek : fgetc(scene_in);
    scene_peek = EOF;
    if (c == EOF) { scene_eof_flag = true; return '\n'; }
    return (uint16_t)(unsigned char)c;
}

static bool scene_eof(void *NOTUSED_data) {
    (void)NOTUSED_data;
    if (scene_eof_flag) return true;
    scene_peek = fgetc(scene_in);
    if (scene_peek == EOF) { scene_eof_flag = true; return true; }
    return false;
}

static void scene_write_char(void *NOTUSED_data, uint8_t c) {
    (void)NOTUSED_data;
    fputc(c, stdout);
}

static void scene_write_buffer(void *NOTUSED_data, uint8_t *buf, uint16_t len) {
    (void)NOTUSED_data;
    fwrite(buf, 1, len, stdout);
}

static void scene_print_dbg(const char *s) {
    (void)s;   // parse/validate diagnostics are noise here
}

static void mode_scene(const char *path) {
    scene_in = fopen(path, "rb");
    if (!scene_in) { fprintf(stderr, "cannot open %s\n", path); return; }
    scene_peek = EOF;
    scene_eof_flag = false;

    scene_state_t ss;
    ss_init(&ss);
    static char text[SCENE_TEXT_LINES][SCENE_TEXT_CHARS];
    memset(text, 0, sizeof(text));

    tt_deserializer_t din = { .read_char = scene_read_char,
                              .eof = scene_eof,
                              .print_dbg = scene_print_dbg,
                              .data = NULL };
    deserialize_scene(&din, &ss, &text);
    fclose(scene_in);

    tt_serializer_t dout = { .write_char = scene_write_char,
                             .write_buffer = scene_write_buffer,
                             .print_dbg = scene_print_dbg,
                             .data = NULL };
    serialize_scene(&dout, &ss, &text);
}

int main(int argc, char **argv) {
    const char *mode = argc > 1 ? argv[1] : "parse";
    if (strcmp(mode, "scene") == 0) {
        if (argc > 2) mode_scene(argv[2]);
        return 0;
    }
    if (strcmp(mode, "random") == 0) dump_random();
    else if (strcmp(mode, "ops") == 0) dump_ops();
    else if (strcmp(mode, "tables") == 0) dump_tables();
    else if (strcmp(mode, "process") == 0) mode_process();
    else mode_parse();
    return 0;
}
