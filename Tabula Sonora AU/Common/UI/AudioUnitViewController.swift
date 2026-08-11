//
//  AudioUnitViewController.swift
//  Tabula Sonora AU
//
//  Created by Kevin López Brante on 10-08-26.
//

import Combine
import CoreAudioKit
import os
import SwiftUI

private let log = Logger(subsystem: "co.losno.Tabula-Sonora-Player.Tabula-Sonora-AU", category: "AudioUnitViewController")

@MainActor
public class AudioUnitViewController: AUViewController, AUAudioUnitFactory {
    var audioUnit: AUAudioUnit?

    var hostingController: HostingController<Tabula_Sonora_AUMainView>?
    
    private var observation: NSKeyValueObservation?

	/* iOS View lifcycle
	public override func viewWillAppear(_ animated: Bool) {
		super.viewWillAppear(animated)

		// Recreate any view related resources here..
	}

	public override func viewDidDisappear(_ animated: Bool) {
		super.viewDidDisappear(animated)

		// Destroy any view related content here..
	}
	*/

	/* macOS View lifcycle
	public override func viewWillAppear() {
		super.viewWillAppear()
		
		// Recreate any view related resources here..
	}

	public override func viewDidDisappear() {
		super.viewDidDisappear()

		// Destroy any view related content here..
	}
	*/

	deinit {
		// The observation registers on the audio unit and is only torn down when it is
		// invalidated or released. Doing it here rather than leaving it to ARC keeps the
		// unit's observer list from outliving the controller that added to it.
		observation?.invalidate()
		observation = nil
	}

    public override func viewDidLoad() {
        super.viewDidLoad()
        
        // Accessing the `audioUnit` parameter prompts the AU to be created via createAudioUnit(with:)
        guard let audioUnit = self.audioUnit else {
            return
        }
        configureSwiftUIView(audioUnit: audioUnit)
    }
    
	nonisolated public func createAudioUnit(with componentDescription: AudioComponentDescription) throws -> AUAudioUnit {
		return try DispatchQueue.main.sync {
			
			// Bound once and used from here down, rather than stored and then read back out
			// through a conditional cast that could only fail by force-unwrapping the same
			// property it had just failed to cast.
			let audioUnit = try Tabula_Sonora_AUAudioUnit(componentDescription: componentDescription,
			                                              options: [])
			self.audioUnit = audioUnit

			defer {
				// Configure the SwiftUI view after creating the AU, instead of in viewDidLoad,
				// so that the parameter tree is set up before we build our @AUParameterUI properties
				DispatchQueue.main.async {
					self.configureSwiftUIView(audioUnit: audioUnit)
				}
			}

			audioUnit.setupParameterTree(Tabula_Sonora_AUParameterSpecs.createAUParameterTree())

			// The observed object rather than the captured `audioUnit`: the observation belongs
			// to this controller and the closure to the observation, so capturing the unit here
			// would give the controller a second hold on it that outlives the host's own.
			self.observation = audioUnit.observe(\.allParameterValues, options: [.new]) { observed, change in
				guard let tree = observed.parameterTree else { return }

				// This insures the Audio Unit gets initial values from the host.
				for param in tree.allParameters { param.value = param.value }
			}
			
			guard audioUnit.parameterTree != nil else {
				log.error("Unable to access AU ParameterTree")
				return audioUnit
			}
			
			return audioUnit
		}
	}
    
    private func configureSwiftUIView(audioUnit: AUAudioUnit) {
        if let host = hostingController {
            host.removeFromParent()
            host.view.removeFromSuperview()
        }
        
        guard let observableParameterTree = audioUnit.observableParameterTree else {
            return
        }
        let content = Tabula_Sonora_AUMainView(parameterTree: observableParameterTree,
                                               audioUnit: audioUnit as? Tabula_Sonora_AUAudioUnit)
        let host = HostingController(rootView: content)
        self.addChild(host)
        host.view.frame = self.view.bounds
        self.view.addSubview(host.view)
        hostingController = host
        
        // Make sure the SwiftUI view fills the full area provided by the view controller
        host.view.translatesAutoresizingMaskIntoConstraints = false
        host.view.topAnchor.constraint(equalTo: self.view.topAnchor).isActive = true
        host.view.leadingAnchor.constraint(equalTo: self.view.leadingAnchor).isActive = true
        host.view.trailingAnchor.constraint(equalTo: self.view.trailingAnchor).isActive = true
        host.view.bottomAnchor.constraint(equalTo: self.view.bottomAnchor).isActive = true
        self.view.bringSubviewToFront(host.view)
    }
    
}
