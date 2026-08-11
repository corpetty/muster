#ifndef RUN_LOG_H
#define RUN_LOG_H

#include <QFile>
#include <QString>

// One run's log file, named the way SessionLogFiles groups a directory back into
// runs: `<stem>_<stamp>.log` is the file being written, `<stem>_<stamp>.NNN.log`
// a rotation of it. The stem is what keeps two writers sharing one directory
// apart.
//
// Not thread-safe.
class RunLog
{
public:
    // Lines before the file being written is moved aside and a fresh one opened.
    static constexpr int kRotateAfterLines = 10000;
    // Runs kept in the directory. Nothing else sweeps it.
    static constexpr int kKeepRuns = 10;

    // Opens a run under `directory`, creating it if it is missing, and prunes all
    // but the newest kKeepRuns runs of this stem. False when there is nowhere to
    // write, leaving the log closed and its path empty.
    bool open(const QString& directory, const QString& stem);

    // Appends one line, rotating first when the file is full. A no-op while the
    // log is closed.
    void write(const QString& line);

    // The file being written, empty while the log is closed. Stays the same
    // across a rotation, because a rotation moves the full file aside rather
    // than the announced one.
    QString path() const;

    bool isOpen() const;

private:
    void rotate();

    QFile m_file;
    QString m_stem;
    QString m_stamp;
    int m_lines = 0;
    int m_rotations = 0;
};

#endif
