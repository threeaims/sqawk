#!/usr/bin/env tclsh
# Sqawk
# Copyright (C) 2015 Danyil Bohdan
# License: MIT
package require Tcl 8.5
package require cmdline
package require struct
package require textutil
package require sqlite3

namespace eval sqawk {
    variable version 0.3.4
    variable debug 0

    proc create-database {database} {
        variable debug

        if {$debug} {
            file delete /tmp/sqawk.db
            ::sqlite3 $database /tmp/sqawk.db
        } else {
            ::sqlite3 $database :memory:
        }
    }

    proc create-table {database table keyPrefix maxNF} {
        set fields {}
        set query {
            CREATE TABLE ${table} (
                ${keyPrefix}nr INTEGER PRIMARY KEY,
                ${keyPrefix}nf INTEGER,
                [join $fields ","]
            )
        }
        for {set i 0} {$i <= $maxNF} {incr i} {
            lappend fields "$keyPrefix$i INTEGER"
        }
        $database eval [subst $query]
    }

    proc insert-data-from-file {fileHandle database table keyPrefix FS RS} {
        set records [::textutil::splitx [read $fileHandle] $RS]
        if {[lindex $records end] eq ""} {
            set records [lrange $records 0 end-1]
        }

        set insertQuery {
            INSERT INTO ${table} ([join $insertColumnNames ","])
            VALUES ([join $insertValues ,])
        }
        foreach record $records {
            set fields [::textutil::splitx $record $FS]
            set insertColumnNames "${keyPrefix}nf,${keyPrefix}0"
            set insertValues  {$nf,$record}
            set nf [llength $fields]
            set i 1
            foreach field $fields {
                set $keyPrefix$i $field
                lappend insertColumnNames "$keyPrefix$i"
                lappend insertValues "\$$keyPrefix$i"
                incr i
            }
            $database eval [subst $insertQuery]
        }
    }

    proc output {data} {
        # Do not throw an error if stdout is closed during output (e.g., if
        # someone is piping the output to head(1)).
        catch {
            puts -nonewline $data
        }
    }

    proc perform-query {database query OFS ORS} {
        $database eval $query results {
            set output {}
            set keys $results(*)
            foreach key $keys {
                lappend output $results($key)
            }
            output [join $output $OFS]$ORS
        }
    }

    proc check-separator-list {sepList fileCount} {
        if {$fileCount != [llength $sepList]} {
            error "given [llength $sepList] separators for $fileCount files"
        }
    }

    proc adjust-separators {key sep agrKey sepList default fileCount} {
        set keyPresent [expr {$sep ne ""}]
        set agrKeyPresent [expr {
            [llength $sepList] > 0
        }]

        if {$keyPresent && $agrKeyPresent} {
            error "cannot specify -$key and -$agrKey at the same time"
        }

        # Set key to its default value.
        if {!$keyPresent && !$agrKeyPresent} {
            set sep $default
            set keyPresent 1
        }

        # Set $agrKey to the value under $key.
        if {$keyPresent && !$agrKeyPresent} {
            set sepList [::struct::list repeat $fileCount $sep]
            set agrKeyPresent 1
        }

        # By now sepList has been set.

        check-separator-list $sepList $fileCount
        return [list $sep $sepList]
    }

    proc process-options {argv} {
        variable version

        set defaultValues {
            FS {[ \t]+}
            RS {\n}
        }

        set options [string map \
                [list %defaultFS %defaultFS %defaultRS %defaultRS] {
            {FS.arg {} "Input field separator (regexp)"}
            {RS.arg {} "Input record separator (regexp)"}
            {FSx.arg {}
                    "Per-file input field separator list (regexp)"}
            {RSx.arg {}
                    "Per-file input record separator list (regexp)"}
            {OFS.arg { } "Output field separator"}
            {ORS.arg {\n} "Output record separator"}
            {NF.arg 10 "Maximum NF value"}
            {v "Print version"}
            {1 "One field only. A shortcut for -FS '^$'"}
        }]
        set usage "?options? script ?filename ...?"
        set cmdOptions [::cmdline::getoptions argv $options $usage]
        set script [lindex $argv 0]
        if {$script eq ""} {
            error "empty script"
        }
        set filenames [lrange $argv 1 end]
        set fileCount [llength $filenames]
        if {$fileCount == 0} {
            set fileCount 1
        }

        if {[dict get $cmdOptions v]} {
            puts $version
            exit 0
        }
        if {[dict get $cmdOptions 1]} {
            dict set cmdOptions FS '^$'
        }


        # The logic for FS and RS default values and FS and RS determining FSx
        # and RSx if the latter two are not set.
        foreach key {FS RS} {
            set agrKey "${key}x"
            lassign [adjust-separators $key \
                            [dict get $cmdOptions $key] \
                            $agrKey \
                            [dict get $cmdOptions $agrKey] \
                            [dict get $defaultValues $key] \
                            $fileCount] \
                    value \
                    agrValue
            dict set cmdOptions $key $value
            dict set cmdOptions $agrKey $agrValue
        }

        # Substitute slashes. (In FS, RS, FSx and RSx the regexp engine will
        # do this for us.)
        foreach option {OFS ORS} {
            dict set cmdOptions $option [subst -nocommands -novariables \
                    [dict get $cmdOptions $option]]
        }

        return [list $cmdOptions $script $filenames]
    }

    proc main {argv {databaseHandle db}} {
        set error [catch {
            lassign [process-options $argv] settings script filenames
        } errorMessage]
        if {$error} {
            puts "error: $errorMessage"
            exit 1
        }

        if {$filenames eq ""} {
            set fileHandles stdin
        } else {
            set fileHandles [::struct::list mapfor x $filenames {open $x r}]
        }

        create-database $databaseHandle

        set tableNames [split {abcdefghijklmnopqrstuvwxyz} ""]
        set i 1
        foreach fileHandle $fileHandles \
                FS [dict get $settings FSx] \
                RS [dict get $settings RSx] {
            set tableName [lindex $tableNames [expr {$i - 1}]]
            create-table $databaseHandle \
                    $tableName \
                    $tableName \
                    [dict get $settings NF]
            $databaseHandle transaction {
                insert-data-from-file $fileHandle $databaseHandle $tableName \
                        $tableName $FS $RS
            }
            incr i
        }
        perform-query $databaseHandle \
                $script \
                [dict get $settings OFS] \
                [dict get $settings ORS]
    }
}

::sqawk::main $argv
