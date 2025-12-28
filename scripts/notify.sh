root@localhost:~# cat send_notify_v3.sh
#!/bin/bash

# --- 配置部分 ---
TG_BOT_TOKEN="xxxxx"
TG_CHAT_ID="xxxxx"
FILE_NAME="优选完成.txt"
RCLONE_SOURCE="hostbrr:ip/优选完成.txt"
ID_FILE="./.tg_last_msg_id"

# --- 1. 清理上一条消息 (如果有) ---
if [ -f "$ID_FILE" ]; then
    LAST_ID=$(cat "$ID_FILE")
    if [ -n "$LAST_ID" ]; then
        # 删除旧消息不需要静音参数，因为删除本身就是静默的
        curl -s -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/deleteMessage" \
            -d "chat_id=${TG_CHAT_ID}" \
            -d "message_id=${LAST_ID}" > /dev/null
    fi
fi

# --- 2. 执行 Rclone 下载 ---
echo "正在从 $RCLONE_SOURCE 下载文件..."
rclone copy "$RCLONE_SOURCE" ./

# --- 3. 检查文件并发送 ---
if [ -f "$FILE_NAME" ]; then
    echo "文件下载成功，准备发送..."
    
    CONTENT=$(cat "$FILE_NAME")
    if [ -z "$CONTENT" ]; then CONTENT="文件为空"; fi

    # 构建 Markdown 内容
    FINAL_MSG="*✅ 优选任务完成*
\`\`\`
${CONTENT}
\`\`\`"

    # --- 4. 静音发送新消息 ---
    # 增加 -d "disable_notification=true"
    RESPONSE=$(curl -s -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
        -d "chat_id=${TG_CHAT_ID}" \
        -d "parse_mode=Markdown" \
        -d "disable_notification=true" \
        --data-urlencode "text=${FINAL_MSG}")

    # 提取新消息 ID
    NEW_MSG_ID=$(echo "$RESPONSE" | grep -o '"message_id":[0-9]*' | grep -o '[0-9]*')

    if [ -n "$NEW_MSG_ID" ]; then
        echo "静音消息发送成功，ID: $NEW_MSG_ID"
        
        # --- 5. 静音置顶 ---
        # 增加 -d "disable_notification=true"
        curl -s -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/pinChatMessage" \
            -d "chat_id=${TG_CHAT_ID}" \
            -d "message_id=${NEW_MSG_ID}" \
            -d "disable_notification=true" > /dev/null
            
        echo "消息已静音置顶。"

        # --- 6. 保存 ID ---
        echo "$NEW_MSG_ID" > "$ID_FILE"
    else
        echo "发送失败，请检查 Token 或网络。API 返回: $RESPONSE"
    fi

else
    echo "错误：未找到文件 $FILE_NAME"
fi

rm /root/优选.txt /root/优选完成.txt
