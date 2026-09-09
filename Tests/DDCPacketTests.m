#import <Foundation/Foundation.h>
#include "i2c.h"
#include <assert.h>
int main(void) {
    DDCPacket packet = createDDCPacket(LUMINANCE);
    prepareDDCRead(packet.data);
    assert(packet.data[3] == 0xac);
    char reply[12] = {0x6e, (char)0x88, 0x02, 0, 0x10, 0, 0, 100, 0, 75, (char)0x8b, 0};
    DDCValue value = convertI2CtoDDC(reply);
    assert(value.curValue == 75 && value.maxValue == 100);
    reply[10] ^= 1;
    assert(convertI2CtoDDC(reply).curValue == -1);
    reply[10] ^= 1;
    reply[3] = 1;
    assert(convertI2CtoDDC(reply).curValue == -1);
    char stale[] = "eep(40)mccs_";
    assert(convertI2CtoDDC(stale).curValue == -1);
    char empty[12] = {0};
    assert(convertI2CtoDDC(empty).curValue == -1);
    puts("PASS: DDC request checksum, valid read, checksum failure, unsupported reply, stale data, empty reply");
}
