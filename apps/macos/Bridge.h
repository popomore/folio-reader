#ifndef FOLIO_BRIDGE_H
#define FOLIO_BRIDGE_H

#include "Archive.h"

char * _Nullable folio_call(const char * _Nonnull request);
void folio_free(char * _Nullable result);

#endif
