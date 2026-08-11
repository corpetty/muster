#include "SessionLogFiles.h"

#include <QDir>
#include <QFileInfo>
#include <QHash>
#include <QRegularExpression>

#include <algorithm>

namespace {

const QString kStamp = QStringLiteral(R"(\d{8}_\d{6})");

// The rotation ordinal a file name carries, or -1 for the file being written,
// which sorts after every rotation of the same run.
int rotationOf(const QString& fileName)
{
    static const QRegularExpression rotated(QStringLiteral(R"(\.(\d{3})\.log$)"));
    const QRegularExpressionMatch match = rotated.match(fileName);
    return match.hasMatch() ? match.captured(1).toInt() : -1;
}

bool olderFirst(const QString& left, const QString& right)
{
    const int leftRotation = rotationOf(left);
    const int rightRotation = rotationOf(right);
    if (leftRotation == -1)
        return false;
    if (rightRotation == -1)
        return true;
    return leftRotation < rightRotation;
}

} // namespace

QList<SessionLogRun> listSessionLogRuns(const QString& announcedPath)
{
    if (announcedPath.isEmpty())
        return {};

    const QFileInfo announced(announcedPath);
    const QDir directory = announced.absoluteDir();

    static const QRegularExpression announcedName(
        QStringLiteral("^(.+)_(%1)\\.log$").arg(kStamp));
    const QRegularExpressionMatch named = announcedName.match(announced.fileName());
    if (!named.hasMatch()) {
        SessionLogRun lone;
        lone.paths = QStringList{announced.absoluteFilePath()};
        lone.bytes = announced.size();
        return {lone};
    }

    const QRegularExpression runFile(
        QStringLiteral("^%1_(%2)(?:\\.\\d{3})?\\.log$")
            .arg(QRegularExpression::escape(named.captured(1)), kStamp));

    QHash<QString, SessionLogRun> byStamp;
    const QFileInfoList entries = directory.entryInfoList(QDir::Files, QDir::Name);
    for (const QFileInfo& entry : entries) {
        const QRegularExpressionMatch match = runFile.match(entry.fileName());
        if (!match.hasMatch())
            continue;
        SessionLogRun& run = byStamp[match.captured(1)];
        run.stamp = match.captured(1);
        run.paths.append(entry.absoluteFilePath());
        run.bytes += entry.size();
    }

    QList<SessionLogRun> runs = byStamp.values();
    std::sort(runs.begin(), runs.end(), [](const SessionLogRun& left, const SessionLogRun& right) {
        return left.stamp > right.stamp;
    });
    for (SessionLogRun& run : runs)
        std::sort(run.paths.begin(), run.paths.end(), olderFirst);

    return runs;
}
