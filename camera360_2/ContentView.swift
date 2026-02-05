//
//  ContentView.swift
//  camera360_2
//
//  Created by Marc Holland on 05.02.26.
//

import SwiftUI

struct ContentView: View {
    @StateObject private var camera = CameraController()

    var body: some View {
        NavigationStack {
            EntryView(camera: camera)
        }
        .task {
            camera.start()
        }
    }
}

#if DEBUG
struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
#endif
