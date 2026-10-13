package ohos_app_cangjie_entry.mock

import ohos_app_cangjie_entry.models.Chat
import std.collection.ArrayList

public class MockChatData {
    public static func getMockChats(): Array<Chat> {
        let list = ArrayList<Chat>()

        let c1 = Chat(); c1.id = 1; c1.name = "Alice"; c1.lastMessage = "今天天气真不错！"
        c1.time = "下午 3:42"; c1.unreadCount = 2; c1.avatarText = "A"; c1.avatarColor = 0xFF5A9FFF; c1.isPinned = true
        list.add(c1)

        let c2 = Chat(); c2.id = 2; c2.name = "Bob"; c2.lastMessage = "明天见面吧"
        c2.time = "下午 2:15"; c2.avatarText = "B"; c2.avatarColor = 0xFFFF9F5A
        list.add(c2)

        let c3 = Chat(); c3.id = 3; c3.name = "Carol"; c3.lastMessage = "文件已发送"
        c3.time = "上午 11:20"; c3.unreadCount = 5; c3.avatarText = "C"; c3.avatarColor = 0xFF9F5AFF
        list.add(c3)

        let c4 = Chat(); c4.id = 4; c4.name = "David"; c4.lastMessage = "好的，收到！"
        c4.time = "上午 9:30"; c4.avatarText = "D"; c4.avatarColor = 0xFF5AFF9F
        list.add(c4)

        let c5 = Chat(); c5.id = 5; c5.name = "Emma"; c5.lastMessage = "这个想法不错"
        c5.time = "昨天"; c5.unreadCount = 1; c5.avatarText = "E"; c5.avatarColor = 0xFFFF5A9F
        list.add(c5)

        let c6 = Chat(); c6.id = 6; c6.name = "Frank"; c6.lastMessage = "晚上7点开会"
        c6.time = "昨天"; c6.avatarText = "F"; c6.avatarColor = 0xFF5AFFFF
        list.add(c6)

        let c7 = Chat(); c7.id = 7; c7.name = "Grace"; c7.lastMessage = "项目进展如何？"
        c7.time = "周一"; c7.unreadCount = 3; c7.avatarText = "G"; c7.avatarColor = 0xFFFFFF5A
        list.add(c7)

        let c8 = Chat(); c8.id = 8; c8.name = "Henry"; c8.lastMessage = "👍"
        c8.time = "周日"; c8.avatarText = "H"; c8.avatarColor = 0xFF5A5AFF
        list.add(c8)

        return list.toArray()
    }
}
