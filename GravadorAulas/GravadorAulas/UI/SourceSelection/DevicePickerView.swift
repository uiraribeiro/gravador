//
//  DevicePickerView.swift
//  GravadorAulas
//

import SwiftUI

struct DevicePickerView: View {
    let title: String
    let devices: [DeviceRef]
    @Binding var selection: DeviceRef?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Picker(title, selection: $selection) {
                Text("(nenhum)").tag(DeviceRef?.none)
                ForEach(devices) { d in
                    Text(d.displayName).tag(DeviceRef?.some(d))
                }
            }
            .labelsHidden()
        }
    }
}