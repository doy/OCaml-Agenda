(* for time functions *)
open Unix

(* for ansi functions *)
open AnsiLib

(* generic error string *)
let invalid_string = "Invalid choice."

(* our representation of what a date is, note that this gets Marshal'ed.
 * note further that these fields are ordered so that compare (or <, whatever)
 * work appropriately on them.  don't shuffle the fields!  *)
type date = {
    year: int;
    month: int;
    day: int }

(* routines to print out the left-most column of the schedule display *)
let print_date date =
    Printf.printf "%04d/%02d/%02d" date.year date.month date.day
let print_spacer () =
    print_string "        |-"

(* get the current date *)
let gen_date () =
    let time = localtime (time ()) in
    {year = time.tm_year + 1900;
     month = time.tm_mon + 1;
     day = time.tm_mday}

(* datum for a single entry, note that changing this will alter the file format
 * used to store the schedule via Marshal. *)
type repeatT = Weekly | Monthly | Yearly | Never
type item = {
    text: string;
    mutable complete: bool;
    repeat: repeatT;
    date: date option}

(* a helper routine for reading labeled integers with default values *)
let read_int_default tag default =
    Printf.printf "%s [%d]: " tag default;
    let response = read_line () in
    if response = "" then default else int_of_string response

(* read in a whole item, allow user to cancel, return item option *)
let read_item () =
    let our_date = gen_date () in
    let dateq = print_string "Date [Yn]: "; read_line () in
    let (date, repeat) = match dateq with
        |"n" | "N" ->
            (None, Never)
        |_ ->
            let repeatq = print_string "Repeat [w]eekly, repeat [m]onthly, repeat [y]early, [N]ever repeat: "; read_line () in
            let year  = read_int_default "Year"  our_date.year in
            let month = read_int_default "Month" our_date.month in
            let day   = read_int_default "Day"   our_date.day in
            let record_date = Some {year = year; month = month; day = day} in
            match (if repeatq = "" then 'n' else repeatq.[0]) with
                |'w' | 'W' -> (record_date, Weekly)
                |'m' | 'M' -> (record_date, Monthly)
                |'y' | 'Y' -> (record_date, Yearly)
                |_ -> (record_date, Never)
        in
    let text  = print_string "Text: "; read_line () in
    let response = print_string "Confirm [yN]: "; flush Pervasives.stdout;
        read_line () in
    match response.[0] with
    |'y' | 'Y' -> Some {text = text;
                        complete = false;
                        repeat = repeat;
                        date = date}
    |_ -> None

(* this is our working schedule *)
let schedule_title = ref "Agenda"
let schedule = ref (let h = Hashtbl.create 1 in
                    Hashtbl.add h !schedule_title ([]: item list); h)
let filename = (Sys.getenv "HOME") ^ "/.schedule.sch"

(* lexicographic compare on items isn't quite satisfying *)
let compare_items a b =
    match (a.date, b.date) with
        |None,   None   -> 0
        |Some _, None   -> -1
        |None,   Some _ -> 1
        |Some x, Some y -> compare x y

(* check to see if a date record is within num days of the current time *)
let within_days date num =
    let our_date = gen_date () in
    match date with None -> false | Some date ->
        let years = date.year - our_date.year in
        let months = date.month - our_date.month + years*12 in
        let days = date.day - our_date.day + months*30 in
        if days <= num then true else false

(* display the working schedule *)
let display_schedule () =
    let our_date = gen_date () in
    let rec ds_aux items old_date number =
        (* iterate through the sorted items *)
        match items with [] -> () | item :: items ->
        (* print either the date, a dateless line, or a continuation thing *)
        (match item.date with
            |None -> print_string "----------"
            |Some date ->
                if date <> old_date then print_date date else print_spacer () );
        print_string " [";
        (* this is the part that deals with the checkboxes, ANSI color codes
         * are a bit ugly *)
        print_string (if item.complete then
                            (color_text Blue ^ "x")
                      else if within_days item.date 1 then
                            (set_style [Reset;Bright] Red Black    ^ "!")
                      else if within_days item.date 3 then
                            (set_style [Reset;Bright] Yellow Black ^ "!")
                      else if within_days item.date 7 then
                            (set_style [Reset;Bright] Green Black  ^ "!")
                      else " ");
        print_string (color_text White ^ "] ");
        (* dump text and loop *)
        Printf.printf "%02d %s\n" number item.text;
        match item.date with
            |None -> ds_aux items our_date (number + 1)
            |Some date -> ds_aux items date (number + 1) in
    (* print the header *)
    print_string AnsiLib.reset_cursor;
    let header = (set_style [Reset;Bright] White Black) ^ (Printf.sprintf
            "================= List: %s\n%04d/%02d/%02d ====== Today's Date\n"
            !schedule_title our_date.year our_date.month our_date.day) ^
        (set_style [Reset] White Black) in
    print_string header;
    ds_aux (Hashtbl.find !schedule !schedule_title) our_date 1

(* delete the num'th item of schedule *)
let rec delete_item schedule num =
    match schedule with [] -> [] | s :: ss ->
    if num = 1 then ss else s :: delete_item ss (num-1)

(* rip off the head of the schedule until we get to the current date *)
let trim_schedule schedule =
    let our_date = gen_date () in
    let rec ts_aux prefix schedule =
        match schedule with |[] -> List.rev prefix |item :: items ->
            match item.date with
                |None ->
                    ts_aux (item :: prefix) items
                |Some incoming_date ->
                    if incoming_date < our_date then begin
                        (* if it's a repeating item, spawn a new one *)
                        match item.repeat with
                        |Weekly ->
                            let tm : Unix.tm = {tm_sec = 0;
                                      tm_min = 0;
                                      tm_hour = 12;
                                      tm_mday = incoming_date.day + 7;
                                      tm_mon = incoming_date.month - 1;
                                      tm_year = incoming_date.year - 1900;
                                      tm_wday = 0;
                                      tm_yday = 0;
                                      tm_isdst = false} in
                            let (_, tm) = Unix.mktime tm in
                            let new_item = {item with date =
                                Some {year = tm.tm_year + 1900;
                                      month = tm.tm_mon + 1;
                                      day = tm.tm_mday};
                                complete = false} in
                            ts_aux (new_item :: prefix) items
                        |Monthly ->
                            let new_item = {item with date =
                                Some (if incoming_date.month = 12 then
                                        {incoming_date with month = 1;
                                         year = incoming_date.year + 1}
                                    else
                                        {incoming_date with month =
                                            incoming_date.month + 1});
                                complete = false} in
                            ts_aux (new_item :: prefix) items
                        |Yearly ->
                            let new_item = {item with date =
                                Some {incoming_date with year =
                                    incoming_date.year + 1 };
                                complete = false} in
                            ts_aux (new_item :: prefix) items
                        |Never -> ts_aux prefix items
                    end else schedule @ prefix in
    List.sort compare_items (ts_aux [] schedule)

(* file io routines *)
let read_schedule () =
    try
        let fh = open_in_bin filename in
        schedule := Marshal.from_channel fh;
        close_in fh
    with _ -> print_endline "Couldn't open preexisting schedule."

let write_schedule () =
    try
        let fh = open_out_bin filename in
        Marshal.to_channel fh !schedule [];
        close_out fh
    with _ -> print_endline "Couldn't write changes to schedule."

let alter_schedule f =
    Hashtbl.replace !schedule !schedule_title
        (f (Hashtbl.find !schedule !schedule_title))

(* the main loop for the program *)
let rec loop () =
    alter_schedule trim_schedule;
    print_string (clear_screen ());
    display_schedule ();
    do_menu menu
(* parses the 'menu' list given below, handles an abstract UI *)
and do_menu menu =
    let rec print_menu menu =
        match menu with [] -> () | (item, c, _) :: menu ->
        Printf.printf "%c) %s\n" c item;
        print_menu menu in
    (* print the menu *)
    print_menu menu;
    (* ask for a choice *)
    try
        print_string "Choice: ";
        let choice = (String.uppercase(read_line ())).[0] in
        let rec iterate menu choice =
            match menu with
                (_, c, f) :: menu -> if c = choice then f () else iterate menu choice
               |[] -> raise (Failure invalid_string) in
        iterate menu choice
    with _ ->
        (* if the user fucked up, do it again *)
        loop ()
(* and the meaty part of the menu, parsed by do_menu *)
and menu =
    ["Add item", 'A', (fun () ->
        begin match read_item () with None -> () | Some item ->
        alter_schedule (fun x -> List.sort compare_items (item :: x)) end;
        loop ());
     "Toggle completion", 'T', (fun () ->
         print_string "Item: ";
         let sched = Hashtbl.find !schedule !schedule_title in
         begin try
             let i = List.nth sched (read_int () - 1) in
             i.complete <- not i.complete
         with _ -> print_endline invalid_string end;
         loop ());
     "Delete item", 'D', (fun () ->
         print_string "Item: ";
         alter_schedule (fun x -> delete_item x (read_int ()));
         loop ());
     "Refresh screen", 'R', loop;
     "Write schedule", 'W', (fun () -> write_schedule (); loop ());
     "Change schedule", 'S', (fun () ->
        print_endline "Available lists are:";
        Hashtbl.iter (fun a b -> print_endline ("    " ^ a)) !schedule;
        print_string "Change list to: ";
        let response = read_line () in
        begin try let _ = Hashtbl.find !schedule response in
            schedule_title := response
        with Not_found ->
            print_string "Schedule does not exist!  Do you want to create it? [yN]: ";
            match read_line () with
                |"Y" | "y" ->
                    schedule_title := response;
                    Hashtbl.add !schedule response []
                |_ -> () end;
        loop ());
     "Quit", 'Q', (fun () -> ())]

(* entry point for the program *)
let _ =
    read_schedule ();
    loop ();
    write_schedule ()
