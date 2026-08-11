#include "MessageListModel.h"

#include "Identity.h"
#include "TimeFormat.h"

#include <QDate>
#include <QLocale>
#include <algorithm>
#include <utility>

MessageListModel::MessageListModel(QObject* parent)
    : QAbstractListModel(parent)
{
}

int MessageListModel::rowCount(const QModelIndex& parent) const
{
    if (parent.isValid()) return 0;
    return m_items.size();
}

QVariant MessageListModel::data(const QModelIndex& index, int role) const
{
    if (!index.isValid() || index.row() >= m_items.size())
        return {};

    const auto& item = m_items.at(index.row());
    // The older neighbour renders directly above this row (newest-first model,
    // BottomToTop list), so index+1 is the chronologically previous message.
    const int older = index.row() + 1;
    switch (role) {
    case SenderRole:    return item.sender;
    case ContentRole:   return item.content;
    case TimestampRole: return item.timestamp;
    case IsMeRole:      return item.isMe;
    case SameSenderAsPreviousRole: {
        if (older >= m_items.size()) return false;
        const auto& prev = m_items.at(older);
        return item.sender == prev.sender && item.isMe == prev.isMe
            && item.timestamp.date() == prev.timestamp.date();
    }
    case ShowDaySeparatorRole:
        return older >= m_items.size() || item.timestamp.date() != m_items.at(older).timestamp.date();
    case DayLabelRole:  return dayLabel(item.timestamp);
    case TimeDisplayRole: return TimeFormat::shortTime(item.timestamp);
    case AvatarInitialsRole: return Identity::initials(item.sender);
    case AvatarRampRole:     return Identity::avatarRamp(item.sender);
    default:            return {};
    }
}

QHash<int, QByteArray> MessageListModel::roleNames() const
{
    return {
        { SenderRole,                 "sender" },
        { ContentRole,                "content" },
        { TimestampRole,              "timestamp" },
        { IsMeRole,                   "isMe" },
        { SameSenderAsPreviousRole,   "sameSenderAsPrevious" },
        { ShowDaySeparatorRole,       "showDaySeparator" },
        { DayLabelRole,               "dayLabel" },
        { TimeDisplayRole,            "timeDisplay" },
        { AvatarInitialsRole,         "avatarInitials" },
        { AvatarRampRole,             "avatarRamp" }
    };
}

void MessageListModel::addMessage(const QString& sender, const QString& content,
                                  const QDateTime& timestamp, bool isMe)
{
    // Drop an exact duplicate of the newest message. A reconnect resync reloads
    // the active thread via get_messages while live events still push, so a
    // message persisted just before the reload and delivered just after would
    // otherwise appear twice; distinct messages never share content + timestamp
    // + sender. The model is newest-first, so the newest row is the front.
    if (!m_items.isEmpty()) {
        const MessageItem& newest = m_items.first();
        if (newest.isMe == isMe && newest.timestamp == timestamp && newest.content == content)
            return;
    }

    beginInsertRows(QModelIndex(), 0, 0);
    m_items.prepend({ sender, content, timestamp, isMe });
    endInsertRows();
}

void MessageListModel::addMessages(QVector<MessageItem> items)
{
    const int n = items.size();
    if (n == 0) return;

    // get_messages returns the thread oldest-first; the model is newest-first
    // (row 0 is the newest message, which the BottomToTop list pins to the
    // visual bottom), so reverse the batch before appending it as older history.
    std::reverse(items.begin(), items.end());
    const int firstRow = m_items.size();
    beginInsertRows(QModelIndex(), firstRow, firstRow + n - 1);
    m_items += std::move(items);
    endInsertRows();

    // The row that was oldest now has an older neighbour beneath it, so its
    // day-separator and grouping flags may have flipped.
    if (firstRow > 0)
        emit dataChanged(index(firstRow - 1), index(firstRow - 1),
                         { SameSenderAsPreviousRole, ShowDaySeparatorRole });
}

void MessageListModel::setMessages(QVector<MessageItem> items)
{
    // Replace the whole thread in a single reset. get_messages returns the
    // thread oldest-first and the model is newest-first, so reverse as
    // addMessages does. Doing this as one reset (rather than clear() then
    // addMessages()) means the list never passes through an empty state, so
    // switching conversations does not flash the view empty.
    std::reverse(items.begin(), items.end());
    beginResetModel();
    m_items = std::move(items);
    endResetModel();
}

void MessageListModel::clear()
{
    if (m_items.isEmpty()) return;
    beginResetModel();
    m_items.clear();
    endResetModel();
}

QString MessageListModel::dayLabel(const QDateTime& timestamp) const
{
    if (!timestamp.isValid())
        return {};

    const QDate today = QDate::currentDate();
    const QDate date = timestamp.date();
    if (date == today)
        return tr("Today");
    if (date == today.addDays(-1))
        return tr("Yesterday");
    return QLocale::system().toString(date, QLocale::ShortFormat);
}
