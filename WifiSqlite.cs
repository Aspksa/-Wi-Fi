using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;

[assembly: DefaultDllImportSearchPaths(DllImportSearchPath.System32)]

namespace WiFi
{
    public sealed class Sqlite : IDisposable
    {
        private const string Library = "winsqlite3.dll";
        private const CallingConvention Convention = CallingConvention.Cdecl;
        private IntPtr database;

        [DllImport(Library, CallingConvention = Convention)]
        private static extern int sqlite3_open_v2(byte[] file, out IntPtr db, int flags, IntPtr vfs);
        [DllImport(Library, CallingConvention = Convention)]
        private static extern int sqlite3_close(IntPtr db);
        [DllImport(Library, CallingConvention = Convention)]
        private static extern IntPtr sqlite3_backup_init(IntPtr destination, byte[] destinationName,
            IntPtr source, byte[] sourceName);
        [DllImport(Library, CallingConvention = Convention)]
        private static extern int sqlite3_backup_step(IntPtr backup, int pages);
        [DllImport(Library, CallingConvention = Convention)]
        private static extern int sqlite3_backup_finish(IntPtr backup);
        [DllImport(Library, CallingConvention = Convention)]
        private static extern int sqlite3_busy_timeout(IntPtr db, int milliseconds);
        [DllImport(Library, CallingConvention = Convention)]
        private static extern IntPtr sqlite3_errmsg(IntPtr db);
        [DllImport(Library, CallingConvention = Convention)]
        private static extern int sqlite3_prepare_v2(IntPtr db, byte[] sql, int length, out IntPtr statement, IntPtr tail);
        [DllImport(Library, CallingConvention = Convention)]
        private static extern int sqlite3_finalize(IntPtr statement);
        [DllImport(Library, CallingConvention = Convention)]
        private static extern int sqlite3_bind_parameter_count(IntPtr statement);
        [DllImport(Library, CallingConvention = Convention)]
        private static extern int sqlite3_bind_null(IntPtr statement, int position);
        [DllImport(Library, CallingConvention = Convention)]
        private static extern int sqlite3_bind_int64(IntPtr statement, int position, long value);
        [DllImport(Library, CallingConvention = Convention)]
        private static extern int sqlite3_bind_double(IntPtr statement, int position, double value);
        [DllImport(Library, CallingConvention = Convention)]
        private static extern int sqlite3_bind_text(IntPtr statement, int position, byte[] value, int length, IntPtr destructor);
        [DllImport(Library, CallingConvention = Convention)]
        private static extern int sqlite3_step(IntPtr statement);
        [DllImport(Library, CallingConvention = Convention)]
        private static extern int sqlite3_column_count(IntPtr statement);
        [DllImport(Library, CallingConvention = Convention)]
        private static extern int sqlite3_column_type(IntPtr statement, int field);
        [DllImport(Library, CallingConvention = Convention)]
        private static extern long sqlite3_column_int64(IntPtr statement, int field);
        [DllImport(Library, CallingConvention = Convention)]
        private static extern double sqlite3_column_double(IntPtr statement, int field);
        [DllImport(Library, CallingConvention = Convention)]
        private static extern IntPtr sqlite3_column_text(IntPtr statement, int field);
        [DllImport(Library, CallingConvention = Convention)]
        private static extern int sqlite3_column_bytes(IntPtr statement, int field);

        public Sqlite(string file)
        {
            int result = sqlite3_open_v2(Utf8(file), out database, 2 | 4, IntPtr.Zero);
            try
            {
                Check(result);
                Check(sqlite3_busy_timeout(database, 500));
            }
            catch
            {
                Dispose();
                throw;
            }
        }

        private static byte[] Utf8(string text) { return Encoding.UTF8.GetBytes(text + "\0"); }

        private static string ReadText(IntPtr pointer, int length)
        {
            if (pointer == IntPtr.Zero) { return null; }
            if (length < 0)
            {
                length = 0;
                while (Marshal.ReadByte(pointer, length) != 0) { length++; }
            }
            byte[] bytes = new byte[length];
            Marshal.Copy(pointer, bytes, 0, length);
            return Encoding.UTF8.GetString(bytes);
        }

        private void Check(int result)
        {
            if (result != 0)
            {
                throw new IOException("SQLite (" + result + "): " + ReadText(sqlite3_errmsg(database), -1));
            }
        }

        private void Bind(IntPtr statement, int position, object value)
        {
            if (value == null) { Check(sqlite3_bind_null(statement, position)); }
            else if (value is int || value is long || value is bool)
            {
                Check(sqlite3_bind_int64(statement, position, Convert.ToInt64(value, CultureInfo.InvariantCulture)));
            }
            else if (value is double || value is float)
            {
                Check(sqlite3_bind_double(statement, position, Convert.ToDouble(value, CultureInfo.InvariantCulture)));
            }
            else
            {
                byte[] text = Utf8(Convert.ToString(value, CultureInfo.InvariantCulture));
                Check(sqlite3_bind_text(statement, position, text, text.Length - 1, new IntPtr(-1)));
            }
        }

        private object ReadColumn(IntPtr statement, int column)
        {
            switch (sqlite3_column_type(statement, column))
            {
                case 1: return sqlite3_column_int64(statement, column);
                case 2: return sqlite3_column_double(statement, column);
                case 3: return ReadText(sqlite3_column_text(statement, column), sqlite3_column_bytes(statement, column));
                case 5: return null;
                default: throw new InvalidOperationException("Unsupported SQLite column type.");
            }
        }

        public List<object[]> Query(string sql, object[] parameters)
        {
            if (database == IntPtr.Zero) { throw new ObjectDisposedException("Sqlite"); }
            IntPtr statement = IntPtr.Zero;
            try
            {
                Check(sqlite3_prepare_v2(database, Utf8(sql), -1, out statement, IntPtr.Zero));
                if (sqlite3_bind_parameter_count(statement) != parameters.Length)
                {
                    throw new ArgumentException("Unexpected SQL parameter count.", "parameters");
                }
                for (int index = 0; index < parameters.Length; index++) { Bind(statement, index + 1, parameters[index]); }
                var rows = new List<object[]>();
                int result;
                while ((result = sqlite3_step(statement)) == 100)
                {
                    var row = new object[sqlite3_column_count(statement)];
                    for (int column = 0; column < row.Length; column++) { row[column] = ReadColumn(statement, column); }
                    rows.Add(row);
                }
                if (result != 101) { Check(result); }
                return rows;
            }
            finally
            {
                if (statement != IntPtr.Zero) { sqlite3_finalize(statement); }
            }
        }

        // Online SQLite snapshot API: includes committed WAL transactions, unlike a raw file copy.
        public void Backup(string destination)
        {
            if (database == IntPtr.Zero) { throw new ObjectDisposedException("Sqlite"); }
            using (var target = new Sqlite(destination))
            {
                IntPtr backup = sqlite3_backup_init(target.database, Utf8("main"), database, Utf8("main"));
                if (backup == IntPtr.Zero) { throw new IOException("SQLite backup initialization failed."); }
                int step, finish;
                try { step = sqlite3_backup_step(backup, -1); }
                finally { finish = sqlite3_backup_finish(backup); }
                if (step != 101 || finish != 0) { throw new IOException("SQLite backup did not complete."); }
            }
        }

        public void Dispose()
        {
            if (database != IntPtr.Zero)
            {
                sqlite3_close(database);
                database = IntPtr.Zero;
            }
        }
    }
}
