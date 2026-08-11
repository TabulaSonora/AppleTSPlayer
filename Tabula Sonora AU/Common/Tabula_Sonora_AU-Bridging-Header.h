//
//  Tabula_Sonora_AU-Bridging-Header.h
//  Tabula Sonora AU
//

// `TSEngine.h` comes in through the kernel, and with it the C functions the render block calls.
// Importing the bridge's header here rather than its Swift module is deliberate: the module belongs
// to the package and is not a product it vends, while the header is on this target's search path
// and gives Swift exactly the same declarations.
#import "Tabula_Sonora_AUParameterAddresses.h"
#import "TSInstrumentKernel.hpp"
#import "Tabula_Sonora_AUAUProcessHelper.hpp"
