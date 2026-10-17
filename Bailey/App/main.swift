import SwiftUI

// The bundled `ssh` symlink runs the internal SSH front end, not the GUI.
if BaileySSHPassthrough.isInvokedAsSSH {
    BaileySSHPassthrough.main()
}

BaileyApp.main()
