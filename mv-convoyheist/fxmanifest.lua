fx_version 'cerulean'
game 'gta5'

author 'Denzel x Claude'
description 'QBCore Convoy Heist Script'
version '2.0.0'

shared_scripts {
    '@qb-core/shared/locale.lua',
    'config.lua',
}

client_scripts {
    'client/main.lua',
}

server_scripts {
    'server/main.lua',
}

ui_page 'html/index.html'

files {
    'html/index.html',
    'html/style.css',
    'html/script.js',
    'html/images/*.svg',
    'html/images/*.png',
    'html/images/*.jpg',
}

dependency 'qb-core'
dependency 'qb-target'
dependency 'qb-menu'
dependency 'qb-minigames'

lua54 'yes'
