#ifndef FOLIO_IOS_BRIDGE_H
#define FOLIO_IOS_BRIDGE_H

char * _Nullable folio_call(const char * _Nonnull request);
void folio_free(char * _Nullable result);

#endif
