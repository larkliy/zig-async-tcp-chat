pub const UserLiterals = struct {
    pub const Joined = "User has joined the chat room.\n";
    pub const Disconnected = "User has disconnected.\n";
};

pub const SystemLiterals = struct {

    pub const Welcome = 
        \\ Welcome to the chat room!
        \\
        \\ Enter your name:
        \\
    ;

    pub const Help = 
        \\ Enter commands or type /help for help:
        \\
        \\ Available commands:
        \\ /who - Shows list of online users
        \\ /exit - Disconnects from the chat room
        \\ /help - Show help message.
        \\
    ;

    pub const MessageTooLong = "Message is too long, please enter a shorter message. Message should be less than 1024 characters.\n";

    pub const KickedByInactivity = "You have been kicked from the chat room due to inactivity.\n";
    pub const UsersOnline = "Users online: {d} \n";
};