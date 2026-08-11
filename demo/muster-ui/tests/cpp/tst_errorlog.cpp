#include <QDateTime>
#include <QTest>
#include <QVariantMap>

#include "ErrorLog.h"

class TestErrorLog : public QObject
{
    Q_OBJECT

private slots:
    void listsNewestFirst();
    void collapsesConsecutiveRepeats();
    void separatesRepeatsSomethingElseCameBetween();
    void keepsTheNewestWhenTheCapIsReached();

private:
    // A fixed clock, so a row's time is something the test can name.
    static QDateTime at(int minute, int second);
};

QDateTime TestErrorLog::at(int minute, int second)
{
    return QDateTime(QDate(2026, 7, 30), QTime(14, minute, second));
}

void TestErrorLog::listsNewestFirst()
{
    ErrorLog log;
    log.add(QStringLiteral("Failed to create DM: chat is not online"), at(28, 51));
    log.add(QStringLiteral("Failed to add member: no key package for peer"), at(32, 7));

    const QVariantList published = log.published();

    QCOMPARE(published.size(), 2);
    QCOMPARE(published.at(0).toMap().value(QStringLiteral("message")).toString(),
             QStringLiteral("Failed to add member: no key package for peer"));
    QCOMPARE(published.at(0).toMap().value(QStringLiteral("when")).toString(),
             QStringLiteral("14:32:07"));
    QCOMPARE(published.at(1).toMap().value(QStringLiteral("count")).toInt(), 1);
}

void TestErrorLog::collapsesConsecutiveRepeats()
{
    ErrorLog log;
    log.add(QStringLiteral("Delivery error: connection refused"), at(29, 2));
    log.add(QStringLiteral("Delivery error: connection refused"), at(29, 9));
    log.add(QStringLiteral("Delivery error: connection refused"), at(29, 14));

    const QVariantList published = log.published();

    QCOMPARE(published.size(), 1);
    QCOMPARE(published.first().toMap().value(QStringLiteral("count")).toInt(), 3);
    // The row says when the failure started, and the count says it has not
    // stopped.
    QCOMPARE(published.first().toMap().value(QStringLiteral("when")).toString(),
             QStringLiteral("14:29:02"));
}

void TestErrorLog::separatesRepeatsSomethingElseCameBetween()
{
    ErrorLog log;
    log.add(QStringLiteral("Delivery error"), at(29, 2));
    log.add(QStringLiteral("Failed to send message: chat is not online"), at(29, 30));
    log.add(QStringLiteral("Delivery error"), at(30, 1));

    const QVariantList published = log.published();

    QCOMPARE(published.size(), 3);
    for (const QVariant& entry : published)
        QCOMPARE(entry.toMap().value(QStringLiteral("count")).toInt(), 1);
}

void TestErrorLog::keepsTheNewestWhenTheCapIsReached()
{
    ErrorLog log;
    for (int i = 0; i < ErrorLog::kMaxEntries + 5; ++i)
        log.add(QStringLiteral("failure %1").arg(i), at(0, 0));

    const QVariantList published = log.published();

    QCOMPARE(published.size(), ErrorLog::kMaxEntries);
    QCOMPARE(published.first().toMap().value(QStringLiteral("message")).toString(),
             QStringLiteral("failure %1").arg(ErrorLog::kMaxEntries + 4));
    QCOMPARE(published.last().toMap().value(QStringLiteral("message")).toString(),
             QStringLiteral("failure 5"));
}

QTEST_MAIN(TestErrorLog)
#include "tst_errorlog.moc"
