#require "AgentStorage.class.nut:1.0.0"
#require "Rocky.class.nut:1.2.0"
#require "ifttt.class.nut:1.0.0"

// Constants and user strings
const BATTERY_ALERT_THRESHOLD = 2.5;
const BATTERY_ALERT_NOTIFICATION = "Low battery warning";
const MAILBOX_FULL_NOTIFICATION = "You got mail"

// API keywords
const TAG_DATA_WEBHOOK = "webhook";
const TAG_DATA_NAME = "name";

// Initialize services
db <- AgentStorage();
api <- Rocky();
ifttt <- IFTTT("<SECRET_KEY>");

// Wrapper function for sending push notifications - a timestamp will be automatically baked in by IFTTT
function notify(message) {
    ifttt.sendEvent("mailbox_update", message);
}

// Associates the tag with a human-readable name and webhook for delivery acknowledgement
function saveTag(tagId, name, webhook) {
    local tagData = {
        "name" : name,
        "webhook" : webhook
    };

    db.write(tagId, tagData);
}

// Acknowledges delivery to the associated webhook and deleted the tag from the database
function receiveTag(tagId) {
    if(db.exists(tagId)) {
        local tagData = db.remove(tagId);
        if(tagData[TAG_DATA_WEBHOOK] != null) {
            local request = http.get(tagData[TAG_DATA_WEBHOOK]);
            request.sendasync(function(response) {
                // Not our endpoint, so we won't know what to expect here
            });
        }
        
        notify("You got " + tagData[TAG_DATA_NAME]);
    }
}

device.on("update", function(data) {
    server.log(date());
    
    if("voltage" in data && data["voltage"] < BATTERY_ALERT_THRESHOLD) {
        notify(BATTERY_ALERT_NOTIFICATION);
    }
    
    if("error" in data) {
        notify("Error: " + data["error"]);
    }
    
    if("full" in data && data["full"]) {
        notify(MAILBOX_FULL_NOTIFICATION);
    }
    
    if("id" in data) {
        receiveTag(data["id"]);
    }
});

api.post("/tag/register/([^/]*)", function(context) {
    local targetTag = context.matches[1];
    local name = TAG_DATA_NAME in context.req ? context.req[TAG_DATA_NAME]: "a tagged letter";
    local webhook = TAG_DATA_WEBHOOK in context.req ? context.req[TAG_DATA_WEBHOOK]: null;
    
    saveTag(targetTag, name, webhook);
});
