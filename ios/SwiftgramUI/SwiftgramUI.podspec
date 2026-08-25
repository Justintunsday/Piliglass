Pod::Spec.new do |spec|
  spec.name             = 'SwiftgramUI'
  spec.version          = '1.0.0'
  spec.summary          = 'Swiftgram-derived native messaging primitives for PiliGlass.'
  spec.description      = <<-DESC
    A small, Bilibili-model-independent extraction of the list row, message bubble,
    and composer layout used by Swiftgram. It intentionally excludes Telegram's
    AccountContext, Postbox, and networking stack.
  DESC
  spec.homepage         = 'https://github.com/Swiftgram/Telegram-iOS'
  spec.license          = { :type => 'GPL-2.0-or-later', :file => 'NOTICE.md' }
  spec.author           = { 'Swiftgram and Telegram-iOS contributors' => 'https://github.com/Swiftgram/Telegram-iOS' }
  spec.source           = { :path => '.' }
  spec.source_files     = 'Sources/**/*.{swift}'
  spec.ios.deployment_target = '16.0'
  spec.swift_version    = '5.0'
  spec.static_framework = true
  spec.frameworks       = 'SwiftUI', 'UIKit'
end
