#ifndef TIME_FORMAT_H
#define TIME_FORMAT_H

#include <QString>

class QDateTime;

namespace TimeFormat {

// Clock time in the system locale's short form, without seconds. Empty for an
// invalid timestamp.
QString shortTime(const QDateTime& when);

} // namespace TimeFormat

#endif
