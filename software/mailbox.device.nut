#require "ConnectionManager.class.nut:1.0.0"
#require "PN532.class.nut:1.0.0"
#require "TMD2772.class.nut:1.0.0"

class PN532PowerGate {
    
    _disable = null;
    _spi = null;
    
    function constructor(pn532Disable, pn532Spi) {
        _disable = pn532Disable;
        _spi = pn532Spi;
        
        // Set up and shut off PN532 power gate - it will be enabled when needed
        _disable.configure(DIGITAL_OUT, 1);
    }
    
    function enable() {
        _spi.configure(LSB_FIRST | CLOCK_IDLE_HIGH, 2000);
        _disable.write(0);
    }
    
    function disable() {
        _disable.write(1);
        _spi.disable();
    }
}
class AttributePusher {
    
    _data = null;
    
    function constructor() {
        _data = {};
    }
    
    function add(key, value) {
        _data[key] <- value;
        return this;
    }
    
    function addVoltage(value) {
        return add("voltage", value);
    }
    
    function addOpen(isOpen) {
        return add("open", isOpen);
    }
    
    function addFull(isFull) {
        return add("full", isEmpty);
    }
    
    function addError(message) {
        return add("error", message);
    }
    
    function addId(id) {
        return add("id", id);
    }
    
    function send() {
        connectionManager.connectFor(function() {
            agent.send("update", _data);
        }.bindenv(this));
    }
}
class UARTLogger {
    _uart = null;
    _debug = null;
    
    // Pass the UART object ie hardware.uart6E, Baud rate, and Offline Enable True/False
    constructor(uart, baud, enable=true){
        _uart = uart;
        _uart.configure(baud, 8, PARITY_NONE, 1, NO_RX | NO_CTSRTS );
        _debug = enable;
    }
    
    function enable(){_debug = true;}
    
    function disable(){_debug = false;}    
    
    function log(message){
        _debug && _uart.write(message + "\n");
        server.log(message);
    }
}

// These values may need to be tuned for individual installations
const MAILBOX_FULL_THRESHOLD = 1;
const NFC_SCAN_LENGTH = 3;  // In seconds
const WAKEUP_INTERVAL = 86400; // One day
const OPTICAL_SENSOR_PERIOD = 500; // In milliseconds
local UART_ENABLED = true;

interrupt <- hardware.pin1;
spi <- hardware.spi257;
local i2c = hardware.i2c89;
local irq = hardware.pinA;
local ncs = hardware.pinB;
local battery = hardware.pinC;
local pn532Disable = hardware.pinD;

// Returns the voltage as a float
// Note that this is currently a hack due to the fact that the imp002's pin C doesn't have a DAC
function getBatteryVoltage() {
    imp.setpoweren(false);
    return hardware.voltage();
}

function setupInterruptsAndSleep() {    
    // Configure interrupt handler
    interrupt.configure(DIGITAL_IN_WAKEUP, function() {
        server.log("interrupt")
        if(interrupt.read() == 1) {
            onDoorOpen();
        }
    });

    
    // Configure wakeup interrupt
    opticalSense.setWait(OPTICAL_SENSOR_PERIOD);
    opticalSense.setSleepAfterInterrupt(true);
    opticalSense.alsConfigureInterrupt(true, 0, 1, 1);
    opticalSense.alsEnable();

    imp.onidle(function(){
        imp.deepsleepfor(WAKEUP_INTERVAL);
    });
}

// Returns if the prox sensor has detected mail in the mailbox
function isMailboxFull() {
    optical.proximitySetEnabled(true);
    
    // Give the TMD2772 long enough to get a proximity reading
    imp.sleep(0.01);
    
    local proximityReading = optical.proximityRead();
    optical.proximitySetEnabled(false);
    
    return proximityReading >= MAILBOX_FULL_THRESHOLD;
}

// Callback takes error, id
function getNearbyTags(callback) {
    pn532PowerGate.enable();
    local nfc = PN532(spi, ncs, null, irq, function(error) {
        if (error != null) {
            pn532PowerGate.disable();
            callback("Error constructing PN532: " + error, null);
            return;
        }
        
        nfc.enablePowerSaveMode(true, function(error, wasEnabled) {
            if (error != null) {
                pn532PowerGate.disable();
                callback("Error entering power-save mode: " + error, null);
                return;
            }
            
            nfc.pollNearbyTags(PN532.TAG_TYPE_106_A, NFC_SCAN_LENGTH, function(error, numTagsFound, tagData) {
                if (error != null) {
                    pn532PowerGate.disable();
                    callback("Error entering power-save mode: " + error, null);
                    return;
                }
                
                pn532PowerGate.disable();
                
                local foundId = numTagsFound == 1 ? tagData.NFCID : null;
                callback(null, foundId);
            });
        });
    });
}

// Asynchronous, takes a callback
function onDoorOpen(callback) {
    local mailboxFull = isMailboxFull();
    local packet = AttributePusher().addOpen(true).addFull(mailboxFull);
    if(mailboxFull) {
       getNearbyTags(function(error, foundId) {
            if(error != null) {
               packet.addError(error);
            }
            
            if(foundId != null) {
               packet.addId(foundId);
            }
            
            packet.send();
            opticalSense.clearInterrupt();
            callback();
       });
    } else {
        packet.send();
        opticalSense.clearInterrupt();
        callback();
    }
}

debug <- UARTLogger(hardware.uart6E, 19200, UART_ENABLED);

connectionManager <- ConnectionManager({
    "startDisconnected": true
});

pn532PowerGate <- PN532PowerGate(pn532Disable, spi);

// Post battery voltage
// This also has the effect of forcing us online occasionally (at least once per WAKEUP_INTERVAL) to check for software updates
AttributePusher().addVoltage(getBatteryVoltage()).send();

// Set up TMD2772 connection
i2c.configure(CLOCK_SPEED_400_KHZ);
opticalSense <- TMD2772(i2c);

// If the TMD2772 woke us up, jump straight to a scan
// In either case, set up the TMD2772 for interrupts and start a sleep cycle
if(hardware.wakereason() == WAKEREASON_PIN) {
    onDoorOpen(setupInterruptsAndSleep);
} else {
    setupInterruptsAndSleep();
}
