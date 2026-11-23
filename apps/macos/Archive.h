#ifndef FOLIO_ARCHIVE_H
#define FOLIO_ARCHIVE_H

#include <stdint.h>
#include <sys/types.h>

// Public libarchive declarations. macOS ships the library without SDK headers.
struct archive;
struct archive_entry;
struct archive * _Nullable archive_read_new(void);
int archive_read_free(struct archive * _Nonnull);
int archive_read_support_filter_none(struct archive * _Nonnull);
int archive_read_support_filter_gzip(struct archive * _Nonnull);
int archive_read_support_filter_bzip2(struct archive * _Nonnull);
int archive_read_support_filter_xz(struct archive * _Nonnull);
int archive_read_support_format_zip(struct archive * _Nonnull);
int archive_read_support_format_tar(struct archive * _Nonnull);
int archive_read_support_format_7zip(struct archive * _Nonnull);
int archive_read_support_format_rar(struct archive * _Nonnull);
int archive_read_support_format_rar5(struct archive * _Nonnull);
int archive_read_support_format_raw(struct archive * _Nonnull);
int archive_read_open_fd(struct archive * _Nonnull, int, size_t);
int archive_read_next_header(struct archive * _Nonnull, struct archive_entry * _Nullable * _Nonnull);
ssize_t archive_read_data(struct archive * _Nonnull, void * _Nonnull, size_t);
const char * _Nullable archive_error_string(struct archive * _Nonnull);
int archive_format(struct archive * _Nonnull);
int archive_filter_code(struct archive * _Nonnull, int);
int64_t archive_filter_bytes(struct archive * _Nonnull, int);
const char * _Nullable archive_entry_pathname_utf8(struct archive_entry * _Nonnull);
const char * _Nullable archive_entry_pathname(struct archive_entry * _Nonnull);
int64_t archive_entry_size(struct archive_entry * _Nonnull);
mode_t archive_entry_filetype(struct archive_entry * _Nonnull);
const char * _Nullable archive_entry_hardlink(struct archive_entry * _Nonnull);
int archive_entry_is_encrypted(struct archive_entry * _Nonnull);

#endif
