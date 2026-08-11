#ifndef SESSION_LOG_FILES_H
#define SESSION_LOG_FILES_H

#include <QList>
#include <QString>
#include <QStringList>

// One run of one writer, as the log directory holds it. A run is a stamp: the
// writer opens `<stem>_<stamp>.log`, moves it aside as `<stem>_<stamp>.NNN.log`
// when it fills, and opens a fresh file back under the same name, so one run is
// several files and the announced path is always the newest of them.
struct SessionLogRun {
    // The run's start time, in the `yyyyMMdd_HHmmss` form the file names carry.
    QString stamp;
    // Oldest rotation first, the file still being written last.
    QStringList paths;
    qint64 bytes = 0;
};

// Every run of one writer, newest first. The announced path is the file that
// writer is writing, which fixes the directory to read and the stem to group by;
// an empty path has no directory to read and yields nothing.
//
// Grouping by the announced stem is what lets two writers share a directory: a
// list holds its own writer's runs and never the other's.
//
// A path whose name does not carry a stamp is reported as a single run of one
// file: a writer that names its log differently is still worth handing over.
QList<SessionLogRun> listSessionLogRuns(const QString& announcedPath);

#endif
