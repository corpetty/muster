#ifndef MESSAGE_LIST_MODEL_H
#define MESSAGE_LIST_MODEL_H

#include <QAbstractListModel>
#include <QDateTime>
#include <QString>
#include <QVector>

struct MessageItem {
    QString sender;
    QString content;
    QDateTime timestamp;
    bool isMe;
};

class MessageListModel : public QAbstractListModel
{
    Q_OBJECT

public:
    enum Roles {
        SenderRole = Qt::UserRole + 1,
        ContentRole,
        TimestampRole,
        IsMeRole,
        // Neighbour-derived, computed from the chronologically previous (older)
        // message at index+1 (the model is newest-first). Used to group a run of
        // messages and to break the run with a day heading.
        SameSenderAsPreviousRole,
        ShowDaySeparatorRole,
        DayLabelRole,
        // Clock time for the bubble, formatted here so every timestamp in the UI
        // shares one locale and shape.
        TimeDisplayRole,
        // Avatar identity for the sender, on the same rule as the roster's, so
        // a member wears one colour in the thread and in the member list.
        AvatarInitialsRole,
        AvatarRampRole
    };

    explicit MessageListModel(QObject* parent = nullptr);

    int rowCount(const QModelIndex& parent = QModelIndex()) const override;
    QVariant data(const QModelIndex& index, int role) const override;
    QHash<int, QByteArray> roleNames() const override;

    void addMessage(const QString& sender, const QString& content,
                    const QDateTime& timestamp, bool isMe);
    void addMessages(QVector<MessageItem> items);
    void setMessages(QVector<MessageItem> items);
    void clear();

    // Row of the proposal card that minted `intentId`, or -1. Lives here rather
    // than in QML because finding it means reading a role off every row, and
    // the role enum is not registered with the engine — the view would have to
    // know a number. The pinned banner uses it to scroll to the card.
    Q_INVOKABLE int rowOfIntent(const QString& intentId) const;

private:
    // "Today" / "Yesterday" / short date for a day-separator heading.
    QString dayLabel(const QDateTime& timestamp) const;

    QVector<MessageItem> m_items;
};

#endif
