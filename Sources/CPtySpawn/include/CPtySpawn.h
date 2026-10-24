#ifndef CPTYSPAWN_H
#define CPTYSPAWN_H

#include <sys/types.h>

/// Starts `argv` (argv[0] an absolute path) with `envp` in `cwd` on a new pty of the given size,
/// as Ghostty's exec backend does: a new session with the pty as its controlling terminal, IUTF8
/// on, signals back to their defaults, no descriptor but the pty's three. Returns the child's pid
/// and the pty's master side in `master_out`, or -1 with errno set.
///
/// Everything the child does between fork and exec is async-signal-safe: the daemon has threads.
pid_t promptty_pty_spawn(char *const argv[], char *const envp[], const char *cwd,
                         unsigned short cols, unsigned short rows,
                         unsigned short width_px, unsigned short height_px,
                         int *master_out);

/// The pty's slave side's name, for reading its mode (`tcgetattr`), into `buffer`; 0 on success.
int promptty_pty_name(int master, char *buffer, size_t size);

#endif
