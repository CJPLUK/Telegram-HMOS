package ohos_app_cangjie_entry.mock

import ohos_app_cangjie_entry.models.Message
import std.collection.ArrayList

public class MockMessageData {
    public static func getMockMessages(chatName: String): Array<Message> {
        let list = ArrayList<Message>()

        let m1 = Message(); m1.id = 1; m1.content = "你好！"; m1.time = "14:30"; m1.isSent = true; m1.status = "read"; m1.senderId = 1
        list.add(m1)
        let m2 = Message(); m2.id = 2; m2.content = "你好啊！"; m2.time = "14:31"; m2.isSent = false; m2.status = "read"; m2.senderId = 2
        list.add(m2)
        let m3 = Message(); m3.id = 3; m3.content = "今天天气怎么样？"; m3.time = "14:32"; m3.isSent = true; m3.status = "read"; m3.senderId = 1
        list.add(m3)
        let m4 = Message(); m4.id = 4; m4.content = "天气很好，阳光明媚😊"; m4.time = "14:33"; m4.isSent = false; m4.status = "read"; m4.senderId = 2
        list.add(m4)
        let m5 = Message(); m5.id = 5; m5.content = "那我们出去走走吧"; m5.time = "14:34"; m5.isSent = true; m5.status = "read"; m5.senderId = 1
        list.add(m5)
        let m6 = Message(); m6.id = 6; m6.content = "好啊，几点出发？"; m6.time = "14:35"; m6.isSent = false; m6.status = "read"; m6.senderId = 2
        list.add(m6)
        let m7 = Message(); m7.id = 7; m7.content = "下午3点怎么样？"; m7.time = "14:36"; m7.isSent = true; m7.status = "read"; m7.senderId = 1
        list.add(m7)
        let m8 = Message(); m8.id = 8; m8.content = "没问题，到时候见👋"; m8.time = "14:37"; m8.isSent = false; m8.status = "read"; m8.senderId = 2
        list.add(m8)

        return list.toArray()
    }
}
