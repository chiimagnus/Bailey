import SwiftUI

// The bundled `ssh` symlink runs the internal SSH front end, not the GUI.
if KeroSSHPassthrough.isInvokedAsSSH {
    KeroSSHPassthrough.main()
}

keroApp.main()
