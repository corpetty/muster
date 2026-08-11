#include "RunLog.h"

#include "SessionLogFiles.h"

#include <QDateTime>
#include <QDebug>
#include <QDir>
#include <QFileInfo>

bool RunLog::open(const QString& directory, const QString& stem)
{
    if (directory.isEmpty() || !QDir().mkpath(directory))
        return false;

    m_stem = stem;
    m_stamp = QDateTime::currentDateTime().toString(QStringLiteral("yyyyMMdd_HHmmss"));
    m_file.setFileName(
        QDir(directory).filePath(QStringLiteral("%1_%2.log").arg(m_stem, m_stamp)));
    // Appending: two runs starting in the same second share a stamp, and the
    // earlier one's lines are worth more than a tidy file.
    if (!m_file.open(QIODevice::WriteOnly | QIODevice::Append | QIODevice::Text))
        return false;

    // Pruned through the same grouping that reads the directory back, so what
    // counts as a run is decided in one place and another writer's log here is
    // not this one's to delete.
    const QList<SessionLogRun> runs = listSessionLogRuns(m_file.fileName());
    for (qsizetype i = kKeepRuns; i < runs.size(); ++i) {
        for (const QString& path : runs.at(i).paths)
            QFile::remove(path);
    }
    return true;
}

void RunLog::write(const QString& line)
{
    if (!m_file.isOpen())
        return;

    m_file.write(line.toUtf8());
    m_file.write("\n");
    // Flushed per line: a run's log is worth most when the process did not get
    // to close it.
    m_file.flush();

    if (++m_lines >= kRotateAfterLines)
        rotate();
}

QString RunLog::path() const
{
    return m_file.isOpen() ? m_file.fileName() : QString();
}

bool RunLog::isOpen() const
{
    return m_file.isOpen();
}

void RunLog::rotate()
{
    // Spend the budget before trying: a rotation that cannot happen has to be
    // retried when the file is next full, not on every line after this one.
    m_lines = 0;
    ++m_rotations;

    const QString announced = m_file.fileName();
    const QString aside = QDir(QFileInfo(announced).absolutePath())
                              .filePath(QStringLiteral("%1_%2.%3.log")
                                            .arg(m_stem, m_stamp)
                                            .arg(m_rotations, 3, 10, QLatin1Char('0')));
    m_file.close();
    // Reopened either way, and in append mode: a rename that failed leaves the
    // full file where it is, and carrying on in it keeps the rest of the run.
    if (!QFile::rename(announced, aside))
        qWarning() << "chat_ui: could not rotate" << announced << "- it keeps growing";
    if (!m_file.open(QIODevice::WriteOnly | QIODevice::Append | QIODevice::Text))
        qWarning() << "chat_ui: this run's log ends at" << announced << ":" << m_file.errorString();
}
